-- Departments: a department manager sees and runs the department's
-- projects, and no others, without the workspace's admin rights.
-- Uses its own users so it does not depend on other test files.

\set ON_ERROR_STOP on

-- Users: Samir (owner), Dina (sales manager), Fady (member of a sales project).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000086', 'samir@dept.example.com', '{"full_name":"Samir"}'),
  ('00000000-0000-0000-0000-000000000087', 'dina@dept.example.com',  '{"full_name":"Dina"}'),
  ('00000000-0000-0000-0000-000000000088', 'fady@dept.example.com',  '{"full_name":"Fady"}');

create temp table ctx (k text primary key, v text);
grant all on ctx to authenticated;

create function pg_temp.login(n int) returns void language sql as $$
  select set_config('role', 'authenticated', false),
         set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000' || n, false);
$$;

create function pg_temp.check(ok boolean, what text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'FAILED: %', what; end if;
  raise notice 'ok: %', what;
end;
$$;

create function pg_temp.fails(stmt text, err text, what text) returns void language plpgsql as $$
begin
  execute stmt;
  raise exception 'FAILED: % (it worked)', what;
exception when others then
  if sqlerrm like 'FAILED:%' then raise; end if;
  if sqlerrm <> err and sqlstate <> err then
    raise exception 'FAILED: % (got % / %)', what, sqlerrm, sqlstate;
  end if;
  raise notice 'ok: %', what;
end;
$$;

create function pg_temp.v(key text) returns uuid language sql as $$
  select v::uuid from ctx where k = key $$;
create function pg_temp.uid(n int) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-0000000000' || n)::uuid $$;

-- Samir's workspace: two sales projects and an HR one; Fady works on one.
select pg_temp.login(86);
insert into ctx values ('ws', public.create_company_workspace('Dept Co', 'eg', 'Dept Desk'));
insert into public.invites (workspace_id, email, role, invited_by) values
  (pg_temp.v('ws'), 'dina@dept.example.com', 'member', auth.uid()),
  (pg_temp.v('ws'), 'fady@dept.example.com', 'member', auth.uid());
select pg_temp.login(87);
select public.accept_invite((select token from public.my_invites()));
select pg_temp.login(88);
select public.accept_invite((select token from public.my_invites()));
select pg_temp.login(86);
with created as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.v('ws'), 'Sales North', auth.uid()), (pg_temp.v('ws'), 'Sales South', auth.uid()),
         (pg_temp.v('ws'), 'Hiring', auth.uid())
  returning id, name
) insert into ctx select name, id::text from created;
insert into public.project_members (project_id, user_id) values (pg_temp.v('Sales North'), pg_temp.uid(88));
select public.create_task(pg_temp.v('Sales North'), 'Call the client');
select public.create_task(pg_temp.v('Hiring'), 'Interview');

-- 1. Before: Dina sees none of them.
select pg_temp.login(87);
select pg_temp.check(not exists (select 1 from public.projects), 'a member sees no project of others');

-- 2. Only admins keep departments.
select pg_temp.fails($$ select public.save_department(pg_temp.v('ws'), null, 'Sales', '{}', '{}') $$,
  'not_allowed', 'a member cannot make a department');
select pg_temp.login(86);
insert into ctx values ('sales', public.save_department(pg_temp.v('ws'), null, ' Sales ',
  array[pg_temp.uid(87)], array[pg_temp.v('Sales North'), pg_temp.v('Sales South')]));
select pg_temp.fails($$ select public.save_department(pg_temp.v('ws'), null, 'Sales', '{}', '{}') $$,
  'name_taken', 'names are not repeated');
select pg_temp.check(
  (select name = 'Sales' and manager_ids = array[pg_temp.uid(87)] and cardinality(project_ids) = 2
   from public.workspace_departments(pg_temp.v('ws'))),
  'the department has its manager and projects');

-- 3. Dina sees and runs the sales projects only.
select pg_temp.login(87);
select pg_temp.check(
  (select array_agg(name order by name) from public.projects) = array['Sales North', 'Sales South'],
  'a department manager sees its projects');
select pg_temp.check(
  (select array_agg(name) from public.my_departments(pg_temp.v('ws'))) = array['Sales'],
  'and knows which departments are theirs');
select pg_temp.check(public.is_project_lead(pg_temp.v('Sales North'))
  and not public.is_workspace_admin(pg_temp.v('ws')), 'runs them like a lead, not as an admin');
select pg_temp.check(
  (select count(*) from public.tasks where title = 'Call the client') = 1
  and not exists (select 1 from public.tasks where title = 'Interview'),
  'sees their tasks only');
select pg_temp.check(
  public.project_conversation(pg_temp.v('Sales South')) is not null,
  'and their chats');
insert into public.project_members (project_id, user_id) values (pg_temp.v('Sales South'), pg_temp.uid(88));
select pg_temp.check(
  (select count(*) from public.project_members where project_id = pg_temp.v('Sales South')) >= 1,
  'and adds people to them');
select pg_temp.fails($$ select public.save_department(pg_temp.v('ws'), pg_temp.v('sales'), 'Sales', '{}', '{}') $$,
  'not_allowed', 'but does not change the department');

-- 4. The dashboard shows the department only.
select pg_temp.check(
  (select (e ->> 'projects')::int = 2 and (e ->> 'department_only')::boolean
          and e -> 'attendance' = 'null'::jsonb
   from jsonb_array_elements(public.management_overview()) e),
  'the dashboard counts the department''s projects only');
select pg_temp.login(88);
select pg_temp.check(public.management_overview() = '[]'::jsonb, 'a member has no dashboard');

-- 5. A project taken out, and a manager removed.
select pg_temp.login(86);
select public.save_department(pg_temp.v('ws'), pg_temp.v('sales'), 'Sales',
  array[pg_temp.uid(87)], array[pg_temp.v('Sales North')]);
select pg_temp.login(87);
select pg_temp.check(not exists (select 1 from public.projects where name = 'Sales South'),
  'a project out of the department is out of sight');
select pg_temp.login(86);
select public.delete_department(pg_temp.v('sales'));
select pg_temp.login(87);
select pg_temp.check(not exists (select 1 from public.projects), 'and none once it is gone');

reset role;
