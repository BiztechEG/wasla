-- The first-steps checklist of a new workspace: each step is ticked by
-- doing it, and only its owners and admins see it.
-- Uses its own users so it does not depend on other test files.

\set ON_ERROR_STOP on

-- Users: Nada (owner), Karim (joins as a member).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000056', 'nada@setup.example.com',  '{"full_name":"Nada"}'),
  ('00000000-0000-0000-0000-000000000057', 'karim@setup.example.com', '{"full_name":"Karim"}');

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

create function pg_temp.v(key text) returns uuid language sql as $$
  select v::uuid from ctx where k = key $$;
create function pg_temp.steps() returns text language sql as $$
  select concat_ws(',', case when has_project then 'project' end,
                        case when has_team then 'team' end,
                        case when attendance_on then 'attendance' end,
                        case when has_announcement then 'announcement' end)
  from public.workspace_setup(pg_temp.v('ws')) $$;

select pg_temp.login(56);
insert into ctx values ('ws', public.create_company_workspace('Setup Co', 'eg', 'Setup Desk'));
select pg_temp.check(pg_temp.steps() = '', 'a new workspace has every step to do');

with created as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.v('ws'), 'First Project', auth.uid()) returning id
) insert into ctx select 'p', id::text from created;
select pg_temp.check(pg_temp.steps() = 'project', 'a first project ticks its step');

insert into public.invites (workspace_id, email, role, invited_by)
values (pg_temp.v('ws'), 'karim@setup.example.com', 'member', auth.uid());
select pg_temp.check(pg_temp.steps() = 'project,team', 'an invitation ticks the team');

select public.enable_attendance(pg_temp.v('ws'), 'Morning');
select pg_temp.check(pg_temp.steps() = 'project,team,attendance', 'so does turning attendance on');

select public.post_announcement(pg_temp.v('ws'), null, 'Welcome to Setup Desk');
select pg_temp.check(pg_temp.steps() = 'project,team,attendance,announcement',
  'and a first announcement');

-- A member sees nothing.
select pg_temp.login(57);
select public.accept_invite((select token from public.my_invites()));
select pg_temp.check(not exists (select 1 from public.workspace_setup(pg_temp.v('ws'))),
  'a member has no checklist');

reset role;
