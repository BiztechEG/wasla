-- Join links: one code per workspace that an admin shares (in the company's
-- WhatsApp group, on a notice board), instead of inviting people one email
-- at a time.
--
-- * Only owners and admins see, turn on, renew or turn off a workspace's
--   code. Renewing makes the old one stop working at once.
-- * Whoever has the code sees the workspace's name before joining, then
--   either joins straight away (when the admin chose so) or sends a request
--   to join that the admins answer as usual. The plan's seats still apply.
-- * Someone joining straight away is announced to the admins.

create table public.workspace_join_codes (
  workspace_id uuid primary key references public.workspaces (id) on delete cascade,
  code         text not null unique check (code ~ '^[A-HJ-NP-Z2-9]{8}$'),
  auto_join    boolean not null default false,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now()
);

alter table public.workspace_join_codes enable row level security;
revoke all on public.workspace_join_codes from anon, authenticated;

alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('assigned', 'status', 'comment', 'due_changed', 'nudge',
                  'due_soon', 'overdue', 'reminder', 'unassigned', 'deleted',
                  'plan_request', 'invoice', 'plan_active', 'plan_ending', 'plan_expired',
                  'invite', 'invite_accepted', 'join_request',
                  'request_accepted', 'request_declined', 'member_joined'));

-- Eight letters and digits, leaving out the ones easily mixed up (I, O, 0, 1).
create function public.new_join_code()
returns text
language sql volatile set search_path = public, pg_temp as $$
  select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
                           get_byte(b, i) % 32 + 1, 1), '' order by i)
  from (select uuid_send(gen_random_uuid()) as b) r, generate_series(0, 7) i;
$$;

-- What people type: any case, with spaces or dashes.
create function public.clean_join_code(p_code text)
returns text
language sql immutable set search_path = public, pg_temp as $$
  select upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
$$;

-- ---------------------------------------------------------------------------
-- For admins
-- ---------------------------------------------------------------------------

create function public.join_code(p_workspace uuid)
returns table (code text, auto_join boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_workspace_admin(p_workspace) then
    raise exception 'not_allowed';
  end if;
  return query select c.code, c.auto_join from workspace_join_codes c
               where c.workspace_id = p_workspace;
end;
$$;

-- Turns the code on (with a new one when p_renew or there was none), sets
-- whether people join without approval, or turns it off.
create function public.set_join_code(
  p_workspace uuid, p_enabled boolean, p_auto boolean default false, p_renew boolean default false
) returns table (code text, auto_join boolean)
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  tries integer := 0;
begin
  if not public.is_workspace_admin(p_workspace) then
    raise exception 'not_allowed';
  end if;
  if not p_enabled then
    delete from workspace_join_codes where workspace_id = p_workspace;
    return;
  end if;
  loop
    begin
      insert into workspace_join_codes as c (workspace_id, code, auto_join, created_by)
      values (p_workspace, public.new_join_code(), coalesce(p_auto, false), auth.uid())
      on conflict (workspace_id) do update
        set auto_join = excluded.auto_join,
            code = case when p_renew then excluded.code else c.code end,
            created_by = case when p_renew then excluded.created_by else c.created_by end,
            created_at = case when p_renew then now() else c.created_at end;
      exit;
    exception when unique_violation then
      -- Another workspace drew the same code: draw again.
      tries := tries + 1;
      if tries > 5 then raise; end if;
    end;
  end loop;
  return query select c.code, c.auto_join from workspace_join_codes c
               where c.workspace_id = p_workspace;
end;
$$;

-- ---------------------------------------------------------------------------
-- For whoever has the code
-- ---------------------------------------------------------------------------

-- The workspace a code leads to, to show before joining.
create function public.workspace_by_code(p_code text)
returns table (workspace_id uuid, workspace_name text, company_name text,
               auto_join boolean, member boolean, requested boolean)
language sql stable security definer set search_path = public, pg_temp as $$
  select w.id, w.name, co.name, c.auto_join,
         public.is_workspace_member(w.id),
         exists (select 1 from join_requests jr
                 where jr.workspace_id = w.id and jr.user_id = auth.uid()
                   and jr.status = 'pending')
  from workspace_join_codes c
  join workspaces w on w.id = c.workspace_id and w.deleted_at is null
  join companies co on co.id = w.company_id
  where auth.uid() is not null and c.code = public.clean_join_code(p_code);
$$;

-- Joins, or asks to join, with a code. Returns 'joined' or 'requested'.
create function public.join_with_code(p_code text, p_message text default null)
returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me uuid := auth.uid();
  c  workspace_join_codes%rowtype;
begin
  select jc.* into c from workspace_join_codes jc
  join workspaces w on w.id = jc.workspace_id and w.deleted_at is null
  where jc.code = public.clean_join_code(p_code);
  if me is null or c.workspace_id is null then
    raise exception 'code_invalid';
  end if;
  if public.is_workspace_member(c.workspace_id) then
    raise exception 'already_member';
  end if;

  if c.auto_join then
    -- Someone who was removed comes back as a plain member.
    insert into workspace_members (workspace_id, user_id, role)
    values (c.workspace_id, me, 'member')
    on conflict (workspace_id, user_id) do update set role = 'member', status = 'active';
    update join_requests set status = 'cancelled'
    where workspace_id = c.workspace_id and user_id = me and status = 'pending';
    insert into notifications (user_id, workspace_id, kind, actor_id)
    select wm.user_id, c.workspace_id, 'member_joined', me
    from workspace_members wm
    where wm.workspace_id = c.workspace_id and wm.status = 'active'
      and wm.role in ('owner', 'admin') and wm.user_id <> me;
    return 'joined';
  end if;

  if exists (select 1 from join_requests
             where workspace_id = c.workspace_id and user_id = me and status = 'pending') then
    return 'requested';
  end if;
  if (select count(*) from join_requests
      where user_id = me and created_at > now() - interval '1 day') >= 30
     or (select count(*) from join_requests
         where user_id = me and workspace_id = c.workspace_id
           and created_at > now() - interval '1 day') >= 5 then
    raise exception 'too_many_requests';
  end if;
  insert into join_requests (workspace_id, user_id, message)
  values (c.workspace_id, me, nullif(trim(left(p_message, 500)), ''));
  return 'requested';
end;
$$;

-- ---------------------------------------------------------------------------
-- Phones: someone who joined opens the members.
-- ---------------------------------------------------------------------------

create or replace function public.push_notification()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  actor text;
  title text;
begin
  select full_name into actor from profiles where id = new.actor_id;
  if new.task_id is not null then
    select tk.title into title from tasks tk where tk.id = new.task_id;
  else
    select name into title from workspaces where id = new.workspace_id;
  end if;
  perform public.queue_push(array[new.user_id], new.workspace_id, new.kind, title, actor,
    new.detail,
    jsonb_build_object(
      'type', case when new.task_id is not null and new.kind <> 'deleted' then 'task'
                   when new.kind = 'plan_request' then 'admin'
                   when new.kind = 'invite' then 'invites'
                   when new.kind = 'join_request' then 'join_requests'
                   when new.kind in ('invite_accepted', 'member_joined') then 'members'
                   when new.kind = 'request_accepted' then 'workspace'
                   when new.kind = 'request_declined' then 'notifications'
                   when new.task_id is null then 'billing'
                   else 'notifications' end,
      'task', new.task_id,
      'request', coalesce(new.invite_id, new.join_request_id)));
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------

revoke execute on function
  public.new_join_code(),
  public.clean_join_code(text),
  public.join_code(uuid),
  public.set_join_code(uuid, boolean, boolean, boolean),
  public.workspace_by_code(text),
  public.join_with_code(text, text)
from public, anon, authenticated;

grant execute on function
  public.join_code(uuid),
  public.set_join_code(uuid, boolean, boolean, boolean),
  public.workspace_by_code(text),
  public.join_with_code(text, text)
to authenticated;
