-- Wasla: fixes from the first security review.
--
-- * Re-approving a removed member no longer restores an old owner/admin role
--   or their old project memberships.
-- * Creating a project works when the app asks for the new row back.
-- * Invitations: admins can only set who and what role, and an invitation
--   stops working once its sender is no longer an admin.
-- * Accepting an invitation never lowers the role of someone already in.
-- * Two owners leaving at the same moment cannot leave a workspace ownerless.
-- * Search treats % and _ as plain text.
-- * Size limits on names and messages, and daily limits on invitations and
--   join requests.
-- * People removed from a workspace stop seeing its members' contact details.
-- * Profile email and phone follow changes made through sign-in.
--
-- Note: migration 2's "alter default privileges ... revoke execute" does not
-- stop Postgres's built-in PUBLIC execute grant on new functions. Every
-- migration must keep revoking execute from public and anon on the functions
-- it creates; supabase/tests/security_test.sql fails if one is missed.

-- ---------------------------------------------------------------------------
-- Leaving a workspace drops its project memberships.
-- ---------------------------------------------------------------------------

create function public.drop_project_memberships()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  delete from project_members pm
  using projects pr
  where pr.id = pm.project_id
    and pr.workspace_id = new.workspace_id
    and pm.user_id = new.user_id;
  return new;
end;
$$;

create trigger workspace_members_left
  after update of status on public.workspace_members
  for each row when (old.status = 'active' and new.status = 'inactive')
  execute function public.drop_project_memberships();

-- ---------------------------------------------------------------------------
-- Join requests: an approved returning member starts as a plain member.
-- ---------------------------------------------------------------------------

create or replace function public.decide_join_request(p_request_id uuid, p_accept boolean)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  req join_requests%rowtype;
begin
  select * into req from join_requests where id = p_request_id for update;
  if req.id is null or req.status <> 'pending' then
    raise exception 'request_invalid';
  end if;
  if not public.is_workspace_admin(req.workspace_id) then
    raise exception 'not_allowed';
  end if;

  if p_accept then
    insert into workspace_members (workspace_id, user_id, role)
    values (req.workspace_id, req.user_id, 'member')
    on conflict (workspace_id, user_id) do update
      set role = case when workspace_members.status = 'active'
                      then workspace_members.role else 'member' end,
          status = 'active';
  end if;

  update join_requests
  set status = case when p_accept then 'accepted'::request_status else 'rejected' end,
      decided_by = auth.uid(), decided_at = now()
  where id = req.id;
end;
$$;

create or replace function public.request_to_join(p_workspace_id uuid, p_message text default null)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me uuid := auth.uid();
  r  uuid;
begin
  if not exists (select 1 from workspaces where id = p_workspace_id and discoverable) then
    raise exception 'workspace_not_found';
  end if;
  if public.is_workspace_member(p_workspace_id) then
    raise exception 'already_member';
  end if;
  if (select count(*) from join_requests
      where user_id = me and created_at > now() - interval '1 day') >= 30
     or (select count(*) from join_requests
         where user_id = me and workspace_id = p_workspace_id
           and created_at > now() - interval '1 day') >= 5 then
    raise exception 'too_many_requests';
  end if;

  insert into join_requests (workspace_id, user_id, message)
  values (p_workspace_id, me, nullif(trim(p_message), ''))
  returning id into r;
  return r;
end;
$$;

-- ---------------------------------------------------------------------------
-- Projects: readable by admins straight from the row, so the creator can get
-- the new project back in the same request.
-- ---------------------------------------------------------------------------

drop policy projects_read on public.projects;
create policy projects_read on public.projects for select to authenticated
  using (
    public.is_workspace_admin(workspace_id)
    or (public.is_workspace_member(workspace_id)
        and exists (select 1 from public.project_members pm
                    where pm.project_id = projects.id and pm.user_id = auth.uid()))
  );

-- ---------------------------------------------------------------------------
-- Invitations
-- ---------------------------------------------------------------------------

-- Admins choose who, which role and which projects; the rest is set here.
revoke insert on public.invites from authenticated;
grant insert (workspace_id, email, phone, role, project_ids, invited_by)
  on public.invites to authenticated;

create function public.limit_invites()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if (select count(*) from invites
      where invited_by = new.invited_by
        and created_at > now() - interval '1 day') >= 300 then
    raise exception 'too_many_invites';
  end if;
  return new;
end;
$$;

create trigger invites_daily_limit
  before insert on public.invites
  for each row execute function public.limit_invites();

create or replace function public.accept_invite(p_token text)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me  uuid := auth.uid();
  inv invites%rowtype;
  usr profiles%rowtype;
  p   uuid;
begin
  select * into usr from profiles where id = me;
  select * into inv from invites where token = p_token for update;

  if inv.id is null or inv.status <> 'pending' or inv.expires_at <= now() then
    raise exception 'invite_invalid';
  end if;
  if not ((inv.email is not null and lower(inv.email) = lower(usr.email))
       or (inv.phone is not null and inv.phone = usr.phone)) then
    raise exception 'invite_not_for_you';
  end if;
  -- An invitation is only as good as the admin who sent it.
  if not exists (select 1 from workspace_members
                 where workspace_id = inv.workspace_id and user_id = inv.invited_by
                   and status = 'active' and role in ('owner', 'admin')) then
    raise exception 'invite_invalid';
  end if;

  -- Someone already in keeps the higher of their role and the invited one
  -- (owner sorts first in the enum).
  insert into workspace_members (workspace_id, user_id, role)
  values (inv.workspace_id, me, inv.role)
  on conflict (workspace_id, user_id) do update
    set role = case when workspace_members.status = 'active'
                    then least(workspace_members.role, excluded.role)
                    else excluded.role end,
        status = 'active';

  foreach p in array inv.project_ids loop
    insert into project_members (project_id, user_id)
    select p, me
    where exists (select 1 from projects where id = p and workspace_id = inv.workspace_id)
    on conflict do nothing;
  end loop;

  update invites set status = 'accepted' where id = inv.id;
  return inv.workspace_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- A workspace always keeps an owner, even when two owners leave at once.
-- ---------------------------------------------------------------------------

create or replace function public.keep_an_owner()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if old.role = 'owner' and old.status = 'active'
     and (new.role <> 'owner' or new.status <> 'active') then
    -- Serialize owner changes per workspace.
    perform 1 from workspaces where id = old.workspace_id for update;
    if not exists (
      select 1 from workspace_members
      where workspace_id = old.workspace_id and user_id <> old.user_id
        and role = 'owner' and status = 'active')
    then
      raise exception 'last_owner' using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Search: % and _ are plain characters.
-- ---------------------------------------------------------------------------

create or replace function public.search_workspaces(p_query text)
returns table (id uuid, name text)
language sql stable security definer set search_path = public, pg_temp as $$
  select w.id, w.name
  from workspaces w
  where w.discoverable
    and length(trim(p_query)) >= 2
    and w.name ilike '%' || replace(replace(replace(trim(p_query),
          '\', '\\'), '%', '\%'), '_', '\_') || '%' escape '\'
  order by w.name
  limit 20;
$$;

-- ---------------------------------------------------------------------------
-- Contact details are shared only between current members.
-- ---------------------------------------------------------------------------

create or replace function public.shares_workspace(other uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1
    from workspace_members a
    join workspace_members b on b.workspace_id = a.workspace_id
    where a.user_id = auth.uid() and a.status = 'active'
      and b.user_id = other and b.status = 'active'
  );
$$;

-- Keep profile email and phone in step with the sign-in account, which only
-- changes them once the new address or number is confirmed.
create function public.sync_profile_contact()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update profiles set email = new.email, phone = new.phone where id = new.id;
  return new;
end;
$$;

create trigger on_auth_user_contact_changed
  after update of email, phone on auth.users
  for each row when (old.email is distinct from new.email
                     or old.phone is distinct from new.phone)
  execute function public.sync_profile_contact();

-- ---------------------------------------------------------------------------
-- Size limits
-- ---------------------------------------------------------------------------

alter table public.profiles      add constraint profiles_full_name_len  check (length(full_name) <= 100);
alter table public.companies     add constraint companies_name_len      check (length(name) <= 100);
alter table public.workspaces    add constraint workspaces_name_len     check (length(name) <= 100);
alter table public.projects      add constraint projects_name_len       check (length(name) <= 100);
alter table public.join_requests add constraint join_requests_msg_len   check (length(message) <= 500);
alter table public.invites       add constraint invites_contact_len
  check (length(email) <= 254 and length(phone) <= 20);

-- ---------------------------------------------------------------------------
-- Privileges for the functions above, and a safe search_path everywhere.
-- ---------------------------------------------------------------------------

revoke execute on function
  public.drop_project_memberships(),
  public.limit_invites(),
  public.sync_profile_contact()
from public, anon, authenticated;

do $$
declare f regprocedure;
begin
  for f in
    select p.oid::regprocedure from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef
  loop
    execute format('alter function %s set search_path = public, pg_temp', f);
  end loop;
end $$;
