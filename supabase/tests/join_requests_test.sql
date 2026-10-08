-- Join requests seen from both sides, and project leads adding people.
-- Uses its own users so it does not depend on other test files.

\set ON_ERROR_STOP on

-- Users: Hala (owner), Tarek (asks to join), Nada (lead), Youssef (outsider).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000101', 'hala@example.com',    '{"full_name":"Hala"}'),
  ('00000000-0000-0000-0000-000000000102', 'tarek@example.com',   '{"full_name":"Tarek"}'),
  ('00000000-0000-0000-0000-000000000103', 'nada@example.com',    '{"full_name":"Nada"}'),
  ('00000000-0000-0000-0000-000000000104', 'youssef@example.com', '{"full_name":"Youssef"}');

create temp table ctx (k text primary key, v text);
grant all on ctx to authenticated;

create function pg_temp.login(n int) returns void language sql as $$
  select set_config('role', 'authenticated', false),
         set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000' || n, false);
$$;

create function pg_temp.check(ok boolean, what text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'FAILED: %', what; end if;
  raise notice 'ok: %', what;
end;
$$;

create function pg_temp.ws() returns uuid language sql as $$ select v::uuid from ctx where k = 'ws' $$;

-- 1. Hala opens a discoverable workspace and invites Nada.
select pg_temp.login(101);
insert into ctx values ('ws', public.create_company_workspace('Delta', 'sa', 'Delta Ops'));
update public.workspaces set discoverable = true where id = pg_temp.ws();
insert into public.invites (workspace_id, email, role, invited_by)
values (pg_temp.ws(), 'nada@example.com', 'member', auth.uid());

select pg_temp.login(103);
select public.accept_invite((select token from public.my_invites()));

-- 2. Tarek asks to join and sees his request by workspace name.
select pg_temp.login(102);
insert into ctx values ('req', public.request_to_join(
  (select id from public.search_workspaces('Delta Ops')), 'I am on the ops team'));
select pg_temp.check(
  (select workspace_name from public.my_join_requests()) = 'Delta Ops',
  'requester sees his pending request with the workspace name');
select pg_temp.check((select count(*) from public.workspaces) = 0,
  'requester still cannot read the workspace');

-- 3. Hala (admin) sees who is asking; Nada (member) and Youssef do not.
select pg_temp.login(101);
select pg_temp.check(
  exists (select 1 from public.profiles where full_name = 'Tarek'),
  'admin sees the profile of someone asking to join');
select pg_temp.login(103);
select pg_temp.check(
  not exists (select 1 from public.profiles where full_name = 'Tarek'),
  'member does not see requester profiles');
select pg_temp.login(104);
select pg_temp.check(
  not exists (select 1 from public.profiles where full_name = 'Tarek'),
  'outsider does not see requester profiles');

-- 4. Tarek withdraws; Hala no longer sees him. He asks again and is accepted.
select pg_temp.login(102);
select public.cancel_join_request((select v::uuid from ctx where k = 'req'));
select pg_temp.check((select count(*) from public.my_join_requests()) = 0, 'request withdrawn');

select pg_temp.login(101);
select pg_temp.check(
  not exists (select 1 from public.profiles where full_name = 'Tarek'),
  'withdrawn request hides the profile again');

select pg_temp.login(102);
update ctx set v = public.request_to_join(pg_temp.ws())::text where k = 'req';
select pg_temp.login(104);
do $$ begin
  perform public.cancel_join_request((select v::uuid from ctx where k = 'req'));
end $$;
select pg_temp.login(102);
select pg_temp.check((select count(*) from public.my_join_requests()) = 1,
  'someone else cannot withdraw my request');

select pg_temp.login(101);
select public.decide_join_request((select v::uuid from ctx where k = 'req'), true);

-- 5. Hala makes a project and makes Nada its lead.
insert into public.projects (workspace_id, name, created_by)
values (pg_temp.ws(), 'Warehouse', auth.uid());
insert into ctx select 'project', id::text from public.projects where name = 'Warehouse';
insert into public.project_members (project_id, user_id, role)
values ((select v::uuid from ctx where k = 'project'), '00000000-0000-0000-0000-000000000103', 'lead');

-- 6. Nada (lead, not admin) adds Tarek but cannot add an outsider.
select pg_temp.login(103);
insert into public.project_members (project_id, user_id)
values ((select v::uuid from ctx where k = 'project'), '00000000-0000-0000-0000-000000000102');
select pg_temp.check((select count(*) from public.project_members
                      where project_id = (select v::uuid from ctx where k = 'project')) = 3,
  'lead adds a workspace member to the project');

do $$ begin
  insert into public.project_members (project_id, user_id)
  values ((select v::uuid from ctx where k = 'project'), '00000000-0000-0000-0000-000000000104');
  raise exception 'FAILED: lead added an outsider';
exception when insufficient_privilege then raise notice 'ok: lead cannot add an outsider';
end $$;

-- 7. Tarek (member) cannot add or remove people.
select pg_temp.login(102);
do $$ begin
  delete from public.project_members
  where project_id = (select v::uuid from ctx where k = 'project')
    and user_id = '00000000-0000-0000-0000-000000000103';
  if found then raise exception 'FAILED: member removed the lead'; end if;
  raise notice 'ok: member cannot remove people';
end $$;

-- 8. New functions are closed to anonymous callers.
reset role;
select pg_temp.check(not has_function_privilege('anon', 'public.my_join_requests()', 'execute'),
  'anon cannot call my_join_requests');

\echo 'all join request tests passed'
