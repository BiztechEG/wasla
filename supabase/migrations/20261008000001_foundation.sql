-- Wasla: phase 1 foundation
-- Companies, workspaces, membership, invites, join requests, projects.
-- Plain PostgreSQL + Row Level Security so it runs on Supabase cloud today
-- and on a self-hosted Postgres later without changes.

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

create type public.workspace_role as enum ('owner', 'admin', 'member');
create type public.project_role   as enum ('lead', 'member');
create type public.member_status  as enum ('active', 'inactive');
create type public.project_status as enum ('active', 'archived', 'closed');
create type public.request_status as enum ('pending', 'accepted', 'rejected', 'cancelled');

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  full_name  text not null default '',
  email      text,
  phone      text,
  locale     text not null default 'ar'     check (locale in ('ar', 'en')),
  theme      text not null default 'system' check (theme in ('light', 'dark', 'system')),
  created_at timestamptz not null default now()
);

-- Pricing is stored in USD; local prices come from exchange rates (phase 4).
create table public.plans (
  id                text primary key,
  name              text not null,
  max_members       integer,          -- null = unlimited (enterprise)
  storage_gb        integer,
  price_usd_month   numeric(10, 2) not null default 0
);

insert into public.plans (id, name, max_members, storage_gb, price_usd_month) values
  ('free',       'Free',       10,   5,    0),
  ('basic',      'Basic',      50,   50,   0),
  ('business',   'Business',   250,  500,  0),
  ('enterprise', 'Enterprise', null, null, 0);

create table public.companies (
  id           uuid primary key default gen_random_uuid(),
  name         text not null check (length(trim(name)) > 0),
  country_code char(2) not null,
  owner_id     uuid not null references public.profiles (id),
  created_at   timestamptz not null default now()
);

create table public.workspaces (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies (id) on delete cascade,
  name         text not null check (length(trim(name)) > 0),
  plan_id      text not null default 'free' references public.plans (id),
  discoverable boolean not null default false,
  created_by   uuid not null references public.profiles (id),
  created_at   timestamptz not null default now()
);

create table public.workspace_members (
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  user_id      uuid not null references public.profiles (id) on delete cascade,
  role         public.workspace_role not null default 'member',
  status       public.member_status  not null default 'active',
  joined_at    timestamptz not null default now(),
  primary key (workspace_id, user_id)
);

create index workspace_members_user_idx on public.workspace_members (user_id);

create table public.invites (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  email        text,
  phone        text,
  role         public.workspace_role not null default 'member' check (role <> 'owner'),
  project_ids  uuid[] not null default '{}',
  token        text not null unique default replace(gen_random_uuid()::text, '-', ''),
  status       public.request_status not null default 'pending',
  invited_by   uuid not null references public.profiles (id),
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '7 days',
  check (email is not null or phone is not null)
);

create table public.join_requests (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  user_id      uuid not null references public.profiles (id) on delete cascade,
  message      text,
  status       public.request_status not null default 'pending',
  decided_by   uuid references public.profiles (id),
  created_at   timestamptz not null default now(),
  decided_at   timestamptz
);

create unique index join_requests_one_pending
  on public.join_requests (workspace_id, user_id) where status = 'pending';

create table public.projects (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  name         text not null check (length(trim(name)) > 0),
  color        text not null default '#0F6E6A',
  status       public.project_status not null default 'active',
  created_by   uuid not null references public.profiles (id),
  created_at   timestamptz not null default now()
);

create index projects_workspace_idx on public.projects (workspace_id);

create table public.project_members (
  project_id uuid not null references public.projects (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  role       public.project_role not null default 'member',
  added_at   timestamptz not null default now(),
  primary key (project_id, user_id)
);

create index project_members_user_idx on public.project_members (user_id);

-- ---------------------------------------------------------------------------
-- Permission helpers (security definer so policies can call them without
-- recursing into the policies of the tables they read)
-- ---------------------------------------------------------------------------

create function public.workspace_role_of(ws uuid)
returns public.workspace_role
language sql stable security definer set search_path = public as $$
  select role from workspace_members
  where workspace_id = ws and user_id = auth.uid() and status = 'active';
$$;

create function public.is_workspace_member(ws uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select public.workspace_role_of(ws) is not null;
$$;

create function public.is_workspace_admin(ws uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.workspace_role_of(ws) in ('owner', 'admin'), false);
$$;

create function public.is_project_lead(p uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from project_members pm
    join projects pr on pr.id = pm.project_id
    where pm.project_id = p and pm.user_id = auth.uid() and pm.role = 'lead'
      and public.is_workspace_member(pr.workspace_id)
  );
$$;

-- Project members see a project; workspace owners and admins see every project.
create function public.can_see_project(p uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from projects pr
    where pr.id = p
      and public.is_workspace_member(pr.workspace_id)
      and (
        public.is_workspace_admin(pr.workspace_id)
        or exists (select 1 from project_members pm
                   where pm.project_id = p and pm.user_id = auth.uid())
      )
  );
$$;

create function public.is_company_owner(c uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from companies where id = c and owner_id = auth.uid());
$$;

create function public.can_see_company(c uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_company_owner(c)
      or exists (select 1 from workspaces w
                 where w.company_id = c and public.is_workspace_member(w.id));
$$;

create function public.shares_workspace(other uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from workspace_members a
    join workspace_members b on b.workspace_id = a.workspace_id
    where a.user_id = auth.uid() and a.status = 'active'
      and b.user_id = other
  );
$$;

-- ---------------------------------------------------------------------------
-- Integrity triggers
-- ---------------------------------------------------------------------------

-- Every new auth user gets a profile.
create function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, email, phone, full_name)
  values (new.id, new.email, new.phone,
          coalesce(new.raw_user_meta_data ->> 'full_name', ''));
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- A workspace cannot have more active members than its plan allows.
create function public.enforce_seat_limit()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  seat_limit integer;
  used       integer;
begin
  if new.status <> 'active'
     or (tg_op = 'UPDATE' and old.status = 'active') then
    return new;
  end if;

  -- Lock the workspace so two joins at once cannot both take the last seat.
  select p.max_members into seat_limit
  from workspaces w join plans p on p.id = w.plan_id
  where w.id = new.workspace_id
  for update of w;

  if seat_limit is null then
    return new;
  end if;

  select count(*) into used
  from workspace_members
  where workspace_id = new.workspace_id and status = 'active'
    and user_id <> new.user_id;

  if used >= seat_limit then
    raise exception 'seat_limit_reached' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger workspace_members_seat_limit
  before insert or update of status on public.workspace_members
  for each row execute function public.enforce_seat_limit();

-- A workspace always keeps at least one active owner.
create function public.keep_an_owner()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.role = 'owner' and old.status = 'active'
     and (new.role <> 'owner' or new.status <> 'active')
     and not exists (
       select 1 from workspace_members
       where workspace_id = old.workspace_id and user_id <> old.user_id
         and role = 'owner' and status = 'active')
  then
    raise exception 'last_owner' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger workspace_members_keep_owner
  before update on public.workspace_members
  for each row execute function public.keep_an_owner();

-- Whoever creates a project leads it.
create function public.add_project_creator()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into project_members (project_id, user_id, role)
  values (new.id, new.created_by, 'lead')
  on conflict do nothing;
  return new;
end;
$$;

create trigger projects_add_creator
  after insert on public.projects
  for each row execute function public.add_project_creator();

-- ---------------------------------------------------------------------------
-- Actions (RPC). Membership is only ever created through these.
-- ---------------------------------------------------------------------------

create function public.create_company_workspace(
  p_company_name   text,
  p_country_code   text,
  p_workspace_name text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  c  uuid;
  ws uuid;
begin
  if me is null then raise exception 'not_authenticated'; end if;

  insert into companies (name, country_code, owner_id)
  values (p_company_name, upper(p_country_code), me)
  returning id into c;

  insert into workspaces (company_id, name, created_by)
  values (c, p_workspace_name, me)
  returning id into ws;

  insert into workspace_members (workspace_id, user_id, role)
  values (ws, me, 'owner');

  return ws;
end;
$$;

-- A company owner adds another workspace under the same company (one invoice).
create function public.create_workspace(p_company_id uuid, p_name text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  ws uuid;
begin
  if not exists (select 1 from companies where id = p_company_id and owner_id = me) then
    raise exception 'not_company_owner';
  end if;

  insert into workspaces (company_id, name, created_by)
  values (p_company_id, p_name, me)
  returning id into ws;

  insert into workspace_members (workspace_id, user_id, role)
  values (ws, me, 'owner');

  return ws;
end;
$$;

-- Invites addressed to the signed-in user's email or phone.
create function public.my_invites()
returns table (id uuid, token text, workspace_id uuid, workspace_name text,
               role public.workspace_role, invited_by_name text)
language sql stable security definer set search_path = public as $$
  select i.id, i.token, w.id, w.name, i.role, p.full_name
  from invites i
  join workspaces w on w.id = i.workspace_id
  join profiles p   on p.id = i.invited_by
  join profiles me  on me.id = auth.uid()
  where i.status = 'pending' and i.expires_at > now()
    and ((i.email is not null and lower(i.email) = lower(me.email))
      or (i.phone is not null and i.phone = me.phone));
$$;

create function public.accept_invite(p_token text)
returns uuid
language plpgsql security definer set search_path = public as $$
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

  insert into workspace_members (workspace_id, user_id, role)
  values (inv.workspace_id, me, inv.role)
  on conflict (workspace_id, user_id)
  do update set status = 'active', role = excluded.role;

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

create function public.decline_invite(p_token text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  update invites i set status = 'rejected'
  from profiles me
  where me.id = auth.uid() and i.token = p_token and i.status = 'pending'
    and ((i.email is not null and lower(i.email) = lower(me.email))
      or (i.phone is not null and i.phone = me.phone));
end;
$$;

-- Only workspaces that chose to be discoverable show up in search.
create function public.search_workspaces(p_query text)
returns table (id uuid, name text)
language sql stable security definer set search_path = public as $$
  select w.id, w.name
  from workspaces w
  where w.discoverable
    and length(trim(p_query)) >= 2
    and w.name ilike '%' || trim(p_query) || '%'
  order by w.name
  limit 20;
$$;

create function public.request_to_join(p_workspace_id uuid, p_message text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
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

  insert into join_requests (workspace_id, user_id, message)
  values (p_workspace_id, me, p_message)
  returning id into r;
  return r;
end;
$$;

create function public.decide_join_request(p_request_id uuid, p_accept boolean)
returns void
language plpgsql security definer set search_path = public as $$
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
    on conflict (workspace_id, user_id) do update set status = 'active';
  end if;

  update join_requests
  set status = case when p_accept then 'accepted'::request_status else 'rejected' end,
      decided_by = auth.uid(), decided_at = now()
  where id = req.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------

alter table public.profiles          enable row level security;
alter table public.plans             enable row level security;
alter table public.companies         enable row level security;
alter table public.workspaces        enable row level security;
alter table public.workspace_members enable row level security;
alter table public.invites           enable row level security;
alter table public.join_requests     enable row level security;
alter table public.projects          enable row level security;
alter table public.project_members   enable row level security;

-- Explicit grants: nothing is reachable unless granted here.
revoke all on all tables in schema public from anon, authenticated;

grant select on public.plans to authenticated;
create policy plans_read on public.plans for select to authenticated using (true);

grant select on public.profiles to authenticated;
grant update (full_name, locale, theme) on public.profiles to authenticated;
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.shares_workspace(id));
create policy profiles_update_self on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

grant select on public.companies to authenticated;
grant update (name) on public.companies to authenticated;
create policy companies_read on public.companies for select to authenticated
  using (public.can_see_company(id));
create policy companies_update_owner on public.companies for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- plan_id is not granted: plans change only through billing.
grant select on public.workspaces to authenticated;
grant update (name, discoverable) on public.workspaces to authenticated;
create policy workspaces_read on public.workspaces for select to authenticated
  using (public.is_workspace_member(id) or public.is_company_owner(company_id));
create policy workspaces_update_admin on public.workspaces for update to authenticated
  using (public.is_workspace_admin(id)) with check (public.is_workspace_admin(id));

-- Admins manage roles and deactivate people; only an owner touches owner rows.
grant select on public.workspace_members to authenticated;
grant update (role, status) on public.workspace_members to authenticated;
create policy members_read on public.workspace_members for select to authenticated
  using (public.is_workspace_member(workspace_id));
create policy members_update_admin on public.workspace_members for update to authenticated
  using (public.is_workspace_admin(workspace_id)
         and (role <> 'owner' or public.workspace_role_of(workspace_id) = 'owner'))
  with check (public.is_workspace_admin(workspace_id)
              and (role <> 'owner' or public.workspace_role_of(workspace_id) = 'owner'));

grant select, insert on public.invites to authenticated;
grant update (status) on public.invites to authenticated;
create policy invites_read_admin on public.invites for select to authenticated
  using (public.is_workspace_admin(workspace_id));
create policy invites_create_admin on public.invites for insert to authenticated
  with check (public.is_workspace_admin(workspace_id) and invited_by = auth.uid());
create policy invites_cancel_admin on public.invites for update to authenticated
  using (public.is_workspace_admin(workspace_id))
  with check (public.is_workspace_admin(workspace_id) and status = 'cancelled');

grant select on public.join_requests to authenticated;
create policy join_requests_read on public.join_requests for select to authenticated
  using (user_id = auth.uid() or public.is_workspace_admin(workspace_id));

grant select, insert on public.projects to authenticated;
grant update (name, color, status) on public.projects to authenticated;
create policy projects_read on public.projects for select to authenticated
  using (public.can_see_project(id));
create policy projects_create_admin on public.projects for insert to authenticated
  with check (public.is_workspace_admin(workspace_id) and created_by = auth.uid());
create policy projects_update_admin on public.projects for update to authenticated
  using (public.is_workspace_admin(workspace_id))
  with check (public.is_workspace_admin(workspace_id));

-- Admins and the project's lead add or remove active workspace members.
grant select, insert, delete on public.project_members to authenticated;
grant update (role) on public.project_members to authenticated;
create policy project_members_read on public.project_members for select to authenticated
  using (public.can_see_project(project_id));
create policy project_members_add on public.project_members for insert to authenticated
  with check (
    exists (select 1 from public.projects pr
            join public.workspace_members wm
              on wm.workspace_id = pr.workspace_id
             and wm.user_id = project_members.user_id and wm.status = 'active'
            where pr.id = project_id
              and (public.is_workspace_admin(pr.workspace_id) or public.is_project_lead(pr.id))));
create policy project_members_change on public.project_members for update to authenticated
  using (exists (select 1 from public.projects pr where pr.id = project_id
                 and (public.is_workspace_admin(pr.workspace_id) or public.is_project_lead(pr.id))));
create policy project_members_remove on public.project_members for delete to authenticated
  using (exists (select 1 from public.projects pr where pr.id = project_id
                 and (public.is_workspace_admin(pr.workspace_id) or public.is_project_lead(pr.id))));

-- RPCs are callable by signed-in users only.
revoke execute on all functions in schema public from public, anon;
grant execute on function
  public.workspace_role_of(uuid),
  public.is_workspace_member(uuid),
  public.is_workspace_admin(uuid),
  public.is_project_lead(uuid),
  public.can_see_project(uuid),
  public.shares_workspace(uuid),
  public.is_company_owner(uuid),
  public.can_see_company(uuid),
  public.create_company_workspace(text, text, text),
  public.create_workspace(uuid, text),
  public.my_invites(),
  public.accept_invite(text),
  public.decline_invite(text),
  public.search_workspaces(text),
  public.request_to_join(uuid, text),
  public.decide_join_request(uuid, boolean)
to authenticated;
