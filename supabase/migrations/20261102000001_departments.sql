-- Departments: a workspace's projects grouped, each with its managers.
--
-- * Owners and admins make departments, put projects in them and name their
--   managers (active members of the workspace).
-- * A department manager sees every project of the department and runs it
--   as its leads do (tasks, people, files, the chat), without being one of
--   its members or getting the workspace's admin rights. They also follow
--   it on the management dashboard, in numbers.
-- * This is done where the app asks who sees and who runs a project
--   (can_see_project, is_project_lead and the lists built on them).

create table public.departments (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  name         text not null check (length(trim(name)) between 1 and 80),
  created_at   timestamptz not null default now(),
  unique (workspace_id, name)
);

create table public.department_managers (
  department_id uuid not null references public.departments (id) on delete cascade,
  user_id       uuid not null references public.profiles (id) on delete cascade,
  primary key (department_id, user_id)
);

create index department_managers_user_idx on public.department_managers (user_id);

alter table public.projects
  add column department_id uuid references public.departments (id) on delete set null;

alter table public.departments enable row level security;
alter table public.department_managers enable row level security;
revoke all on public.departments, public.department_managers from anon, authenticated;

-- Whether one manages the department project p is in (and is still in its
-- workspace).
create function public.manages_department_of(p uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from projects pr
    join department_managers dm on dm.department_id = pr.department_id
    where pr.id = p and dm.user_id = auth.uid()
      and public.is_workspace_member(pr.workspace_id)
  );
$$;

-- ---------------------------------------------------------------------------
-- Who sees and who runs a project
-- ---------------------------------------------------------------------------

create or replace function public.is_project_lead(p uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1
    from project_members pm
    join projects pr on pr.id = pm.project_id
    where pm.project_id = p and pm.user_id = auth.uid() and pm.role = 'lead'
      and public.is_workspace_member(pr.workspace_id)
  ) or public.manages_department_of(p);
$$;

create or replace function public.can_see_project(p uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from projects pr
    where pr.id = p
      and public.is_workspace_member(pr.workspace_id)
      and (
        public.is_workspace_admin(pr.workspace_id)
        or exists (select 1 from project_members pm
                   where pm.project_id = p and pm.user_id = auth.uid())
      )
  ) or public.manages_department_of(p);
$$;

drop policy projects_read on public.projects;
create policy projects_read on public.projects for select to authenticated
  using (
    public.is_workspace_admin(workspace_id)
    or (public.is_workspace_member(workspace_id)
        and exists (select 1 from public.project_members pm
                    where pm.project_id = projects.id and pm.user_id = auth.uid()))
    or public.manages_department_of(id)
  );

create or replace function public.my_project_ids()
returns setof uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select pr.id
  from projects pr
  join workspaces w on w.id = pr.workspace_id and w.deleted_at is null
  join workspace_members wm
    on wm.workspace_id = pr.workspace_id and wm.user_id = auth.uid() and wm.status = 'active'
  where wm.role in ('owner', 'admin')
     or exists (select 1 from project_members pm
                where pm.project_id = pr.id and pm.user_id = auth.uid())
     or exists (select 1 from department_managers dm
                where dm.department_id = pr.department_id and dm.user_id = auth.uid());
$$;

create or replace function public.my_managed_project_ids()
returns setof uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select pr.id
  from projects pr
  join workspaces w on w.id = pr.workspace_id and w.deleted_at is null
  join workspace_members wm
    on wm.workspace_id = pr.workspace_id and wm.user_id = auth.uid() and wm.status = 'active'
  where wm.role in ('owner', 'admin')
     or exists (select 1 from project_members pm
                where pm.project_id = pr.id and pm.user_id = auth.uid() and pm.role = 'lead')
     or exists (select 1 from department_managers dm
                where dm.department_id = pr.department_id and dm.user_id = auth.uid());
$$;

create or replace function public.can_keep_templates(p_workspace uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select public.is_workspace_admin(p_workspace)
      or exists (select 1 from project_members pm
                 join projects pr on pr.id = pm.project_id
                 where pr.workspace_id = p_workspace and pm.user_id = auth.uid()
                   and pm.role = 'lead')
      or (public.is_workspace_member(p_workspace)
          and exists (select 1 from department_managers dm
                      join departments d on d.id = dm.department_id
                      where d.workspace_id = p_workspace and dm.user_id = auth.uid()));
$$;

-- ---------------------------------------------------------------------------
-- Keeping departments
-- ---------------------------------------------------------------------------

-- A workspace's departments, for its owners and admins: managers and projects.
create function public.workspace_departments(p_workspace uuid)
returns table (id uuid, name text, manager_ids uuid[], project_ids uuid[])
language sql stable security definer set search_path = public, pg_temp as $$
  select d.id, d.name,
         array(select dm.user_id from department_managers dm where dm.department_id = d.id),
         array(select p.id from projects p where p.department_id = d.id order by p.name)
  from departments d
  where d.workspace_id = p_workspace and public.is_workspace_admin(p_workspace)
  order by d.name;
$$;

-- Departments one manages in a workspace.
create function public.my_departments(p_workspace uuid)
returns table (id uuid, name text)
language sql stable security definer set search_path = public, pg_temp as $$
  select d.id, d.name
  from departments d
  join department_managers dm on dm.department_id = d.id and dm.user_id = auth.uid()
  where d.workspace_id = p_workspace and public.is_workspace_member(p_workspace)
  order by d.name;
$$;

-- Makes (p_department null) or changes a department: its name, managers and
-- projects. Projects left out of the list leave it.
create function public.save_department(
  p_workspace  uuid,
  p_department uuid,
  p_name       text,
  p_managers   uuid[],
  p_projects   uuid[]
) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  d uuid := p_department;
begin
  if not public.is_workspace_admin(p_workspace) then
    raise exception 'not_allowed';
  end if;
  if nullif(trim(p_name), '') is null then
    raise exception 'invalid_name';
  end if;
  if exists (select 1 from unnest(coalesce(p_managers, '{}')) u
             where not exists (select 1 from workspace_members wm
                               where wm.workspace_id = p_workspace and wm.user_id = u
                                 and wm.status = 'active'))
     or exists (select 1 from unnest(coalesce(p_projects, '{}')) x
                where not exists (select 1 from projects p
                                  where p.id = x and p.workspace_id = p_workspace)) then
    raise exception 'not_allowed';
  end if;
  if d is null then
    insert into departments (workspace_id, name) values (p_workspace, trim(p_name))
    returning id into d;
  else
    update departments set name = trim(p_name)
    where id = d and workspace_id = p_workspace;
    if not found then
      raise exception 'not_allowed';
    end if;
  end if;
  delete from department_managers
  where department_id = d and user_id <> all (coalesce(p_managers, '{}'));
  insert into department_managers (department_id, user_id)
  select d, u from unnest(coalesce(p_managers, '{}')) u
  on conflict do nothing;
  update projects set department_id = null
  where department_id = d and id <> all (coalesce(p_projects, '{}'));
  update projects set department_id = d
  where id = any (coalesce(p_projects, '{}')) and workspace_id = p_workspace;
  return d;
exception when unique_violation then
  raise exception 'name_taken';
end;
$$;

create function public.delete_department(p_department uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not exists (select 1 from departments d
                 where d.id = p_department and public.is_workspace_admin(d.workspace_id)) then
    raise exception 'not_allowed';
  end if;
  delete from departments where id = p_department;
end;
$$;

-- Someone who leaves the workspace stops managing its departments.
create function public.department_managers_leave()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.status <> 'active' then
    delete from department_managers dm
    using departments d
    where d.id = dm.department_id and d.workspace_id = new.workspace_id
      and dm.user_id = new.user_id;
  end if;
  return new;
end;
$$;

create trigger department_managers_leave
  after update of status on public.workspace_members
  for each row execute function public.department_managers_leave();

-- ---------------------------------------------------------------------------
-- The management dashboard follows departments too
-- ---------------------------------------------------------------------------

create or replace function public.management_overview()
returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  with runs as (
    -- Workspaces one runs whole.
    select w.id, w.name, co.name as company
    from workspaces w
    join companies co on co.id = w.company_id
    where w.deleted_at is null
      and auth.uid() is not null
      and (co.owner_id = auth.uid()
           or exists (select 1 from workspace_members wm
                      where wm.workspace_id = w.id and wm.user_id = auth.uid()
                        and wm.status = 'active' and wm.role in ('owner', 'admin')))
  ),
  mine as (
    -- And those where one manages a department, for its projects only.
    select r.id, r.name, r.company, true as whole from runs r
    union all
    select w.id, w.name, co.name, false
    from workspaces w
    join companies co on co.id = w.company_id
    where w.deleted_at is null and w.id not in (select id from runs)
      and exists (select 1 from department_managers dm
                  join departments d on d.id = dm.department_id
                  where d.workspace_id = w.id and dm.user_id = auth.uid())
      and public.is_workspace_member(w.id)
  ),
  shown as (
    -- The active projects each shows.
    select p.*
    from projects p
    join mine m on m.id = p.workspace_id
    where p.status = 'active'
      and (m.whole or exists (select 1 from department_managers dm
                              where dm.department_id = p.department_id
                                and dm.user_id = auth.uid()))
  ),
  live as (
    select t.*
    from tasks t
    join shown p on p.id = t.project_id
    where t.deleted_at is null
  )
  select coalesce(jsonb_agg(row order by row ->> 'workspace_name'), '[]')
  from (
    select jsonb_build_object(
      'workspace_id', m.id,
      'workspace_name', m.name,
      'company_name', m.company,
      'members', (select count(*) from workspace_members wm
                  where wm.workspace_id = m.id and wm.status = 'active'),
      'projects', (select count(*) from shown p where p.workspace_id = m.id),
      'department_only', not m.whole,
      'open', (select count(*) from live t
               where t.workspace_id = m.id and t.status <> 'done'),
      'late', (select count(*) from live t
               where t.workspace_id = m.id and t.status <> 'done' and t.due_at < now()),
      'review', (select count(*) from live t
                 where t.workspace_id = m.id and t.status = 'review'),
      'done_week', (select count(*) from live t
                    where t.workspace_id = m.id and t.status = 'done'
                      and t.done_at >= now() - interval '7 days'),
      'done_week_before', (select count(*) from live t
                           where t.workspace_id = m.id and t.status = 'done'
                             and t.done_at >= now() - interval '14 days'
                             and t.done_at < now() - interval '7 days'),
      'messages_week', (select count(*) from messages ms
                        join conversations c on c.id = ms.conversation_id
                        where ms.workspace_id = m.id and c.kind = 'project'
                          and c.project_id in (select id from shown)
                          and ms.deleted_at is null
                          and ms.created_at >= now() - interval '7 days'),
      'active_people_week', (select count(distinct ms.sender_id) from messages ms
                             join conversations c on c.id = ms.conversation_id
                             where ms.workspace_id = m.id and c.kind = 'project'
                               and c.project_id in (select id from shown)
                          and c.project_id in (select id from shown)
                               and ms.deleted_at is null
                               and ms.created_at >= now() - interval '7 days'),
      'attendance', (
        select case when st.workspace_id is null or not st.enabled or not m.whole
                    then null else
          jsonb_build_object(
            'day_off', extract(dow from (now() at time zone st.timezone))::smallint
                       = any (st.weekend_days),
            'people', (select count(*) from attendance_people ap
                       left join workspace_members wm
                         on wm.workspace_id = ap.workspace_id and wm.user_id = ap.user_id
                       where ap.workspace_id = m.id and ap.active
                         and (ap.user_id is null or wm.status = 'active')),
            'present', (select count(*) from attendance_records r
                        join attendance_people ap on ap.id = r.person_id and ap.active
                        where r.workspace_id = m.id
                          and r.day = (now() at time zone st.timezone)::date),
            'late', (select count(*) from attendance_records r
                     join attendance_people ap on ap.id = r.person_id and ap.active
                     where r.workspace_id = m.id and r.late_minutes > 0
                       and r.day = (now() at time zone st.timezone)::date))
        end
        from (select 1) one
        left join attendance_settings st on st.workspace_id = m.id),
      'project_list', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'id', p.id, 'name', p.name, 'color', p.color,
                 'total', (select count(*) from live t where t.project_id = p.id),
                 'open', (select count(*) from live t
                          where t.project_id = p.id and t.status <> 'done'),
                 'late', (select count(*) from live t
                          where t.project_id = p.id and t.status <> 'done'
                            and t.due_at < now()),
                 'done', (select count(*) from live t
                          where t.project_id = p.id and t.status = 'done'))
               order by p.name), '[]')
        from shown p
        where p.workspace_id = m.id)
    ) as row
    from mine m
  ) rows;
$$;

revoke execute on function public.department_managers_leave()
from public, anon, authenticated;
-- manages_department_of is in the projects read policy.
revoke execute on function
  public.manages_department_of(uuid),
  public.workspace_departments(uuid),
  public.my_departments(uuid),
  public.save_department(uuid, uuid, text, uuid[], uuid[]),
  public.delete_department(uuid)
from public, anon;
grant execute on function
  public.manages_department_of(uuid),
  public.workspace_departments(uuid),
  public.my_departments(uuid),
  public.save_department(uuid, uuid, text, uuid[], uuid[]),
  public.delete_department(uuid)
to authenticated;
