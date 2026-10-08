-- Permission tests for the phase 1 foundation.
-- Each check raises an exception on failure, so the run stops at the first problem.

\set ON_ERROR_STOP on

-- Users: Amr (owner), Mona (invited admin), Karim (invited member),
-- Sara (joins by request), Omar (outsider).
insert into auth.users (id, email, phone, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'amr@example.com',   null,          '{"full_name":"Amr"}'),
  ('00000000-0000-0000-0000-00000000000b', 'mona@example.com',  null,          '{"full_name":"Mona"}'),
  ('00000000-0000-0000-0000-00000000000c', null,                '+201000000003','{"full_name":"Karim"}'),
  ('00000000-0000-0000-0000-00000000000d', 'sara@example.com',  null,          '{"full_name":"Sara"}'),
  ('00000000-0000-0000-0000-00000000000e', 'omar@example.com',  null,          '{"full_name":"Omar"}');

-- A tiny plan so the seat limit is easy to hit.
insert into public.plans (id, name, max_members, storage_gb) values ('test3', 'Test', 3, 1);

create temp table ctx (k text primary key, v text);
grant all on ctx to authenticated;

create function pg_temp.login(u char) returns void language sql as $$
  select set_config('role', 'authenticated', false),
         set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000' || u, false);
$$;

create function pg_temp.check(ok boolean, what text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'FAILED: %', what; end if;
  raise notice 'ok: %', what;
end;
$$;

-- 1. Amr creates a company and workspace and becomes its owner.
select pg_temp.login('a');
insert into ctx values ('ws', public.create_company_workspace('Al Nour', 'eg', 'Engineering'));
select pg_temp.check(
  (select role from public.workspace_members
   where workspace_id = (select v::uuid from ctx where k = 'ws')
     and user_id = auth.uid()) = 'owner',
  'creator is owner');

update public.workspaces set discoverable = true where id = (select v::uuid from ctx where k = 'ws');
select pg_temp.check(
  (select discoverable from public.workspaces where id = (select v::uuid from ctx where k = 'ws')),
  'admin can make workspace discoverable');

-- 2. Amr cannot change the plan himself.
do $$ begin
  update public.workspaces set plan_id = 'enterprise';
  raise exception 'FAILED: owner changed plan';
exception when insufficient_privilege then raise notice 'ok: plan cannot be changed from the app';
end $$;

-- 3. Omar, an outsider, sees nothing.
select pg_temp.login('e');
select pg_temp.check((select count(*) from public.workspaces) = 0, 'outsider sees no workspace');
select pg_temp.check((select count(*) from public.companies) = 0, 'outsider sees no company');

-- 4. Amr creates a project and invites Mona (admin, email) and Karim (member, phone, to the project).
select pg_temp.login('a');
insert into public.projects (workspace_id, name, created_by)
values ((select v::uuid from ctx where k = 'ws'), 'New Branch', auth.uid());
insert into ctx select 'project', id::text from public.projects where name = 'New Branch';
select pg_temp.check(
  exists (select 1 from public.project_members
          where project_id = (select v::uuid from ctx where k = 'project')
            and user_id = auth.uid() and role = 'lead'),
  'project creator becomes lead');

insert into public.invites (workspace_id, email, role, invited_by)
values ((select v::uuid from ctx where k = 'ws'), 'MONA@example.com', 'admin', auth.uid());
insert into public.invites (workspace_id, phone, role, project_ids, invited_by)
values ((select v::uuid from ctx where k = 'ws'), '+201000000003', 'member',
        array[(select v::uuid from ctx where k = 'project')], auth.uid());

do $$ begin
  insert into public.invites (workspace_id, email, role, invited_by)
  values ((select v::uuid from ctx where k = 'ws'), 'x@example.com', 'owner', auth.uid());
  raise exception 'FAILED: invited someone as owner';
exception when check_violation then raise notice 'ok: cannot invite an owner';
end $$;

-- 5. Omar cannot use Mona's invite.
select pg_temp.login('e');
select pg_temp.check((select count(*) from public.my_invites()) = 0, 'outsider has no invites');
do $$ begin
  perform public.accept_invite((select token from public.invites limit 1));
  raise exception 'FAILED: outsider read invites table';
exception when others then
  if sqlerrm like 'FAILED%' then raise; end if;
  raise notice 'ok: outsider cannot read or use invites';
end $$;

-- 6. Mona and Karim accept.
select pg_temp.login('b');
select pg_temp.check((select count(*) from public.my_invites()) = 1, 'Mona sees her invite (email case-insensitive)');
select public.accept_invite((select token from public.my_invites()));
select pg_temp.check(public.workspace_role_of((select v::uuid from ctx where k = 'ws')) = 'admin', 'Mona is admin');
select pg_temp.check((select count(*) from public.projects) = 1, 'admin sees every project');

select pg_temp.login('c');
select public.accept_invite((select token from public.my_invites()));
select pg_temp.check((select count(*) from public.projects) = 1, 'Karim sees the project he was invited to');

-- 7. Karim (member) cannot change roles; Mona (admin) cannot demote the owner.
do $$ begin
  update public.workspace_members set role = 'admin' where user_id = auth.uid();
  if found then raise exception 'FAILED: member promoted himself'; end if;
  raise notice 'ok: member cannot change roles';
end $$;

select pg_temp.login('b');
do $$ begin
  update public.workspace_members set role = 'member'
  where user_id = '00000000-0000-0000-0000-00000000000a';
  if found then raise exception 'FAILED: admin demoted owner'; end if;
  raise notice 'ok: admin cannot touch the owner';
end $$;

-- 8. The last owner cannot leave.
select pg_temp.login('a');
do $$ begin
  update public.workspace_members set status = 'inactive' where user_id = auth.uid();
  raise exception 'FAILED: last owner left';
exception when raise_exception then
  if sqlerrm like 'FAILED%' then raise; end if;
  raise notice 'ok: last owner cannot leave';
end $$;

-- 9. A second project Karim is not in stays hidden from him.
insert into public.projects (workspace_id, name, created_by)
values ((select v::uuid from ctx where k = 'ws'), 'Marketing', auth.uid());
select pg_temp.login('c');
select pg_temp.check((select count(*) from public.projects) = 1, 'member does not see other projects');

-- 10. Sara finds the workspace and asks to join; the plan is full at 3 seats.
reset role;
update public.workspaces set plan_id = 'test3';
select pg_temp.login('d');
select pg_temp.check((select count(*) from public.search_workspaces('Engin')) = 1, 'discoverable workspace found by search');
insert into ctx values ('req', public.request_to_join((select id from public.search_workspaces('Engin'))));

select pg_temp.login('c');
do $$ begin
  perform public.decide_join_request((select v::uuid from ctx where k = 'req'), true);
  raise exception 'FAILED: member accepted a join request';
exception when raise_exception then
  if sqlerrm like 'FAILED%' then raise; end if;
  raise notice 'ok: member cannot accept join requests';
end $$;

select pg_temp.login('b');
do $$ begin
  perform public.decide_join_request((select v::uuid from ctx where k = 'req'), true);
  raise exception 'FAILED: joined past the seat limit';
exception when raise_exception then
  if sqlerrm <> 'seat_limit_reached' then raise; end if;
  raise notice 'ok: seat limit enforced';
end $$;

-- 11. After an upgrade the same request goes through.
reset role;
update public.workspaces set plan_id = 'basic';
select pg_temp.login('b');
select public.decide_join_request((select v::uuid from ctx where k = 'req'), true);
select pg_temp.login('d');
select pg_temp.check(public.is_workspace_member((select v::uuid from ctx where k = 'ws')), 'Sara joined after approval');
select pg_temp.check((select count(*) from public.projects) = 0, 'new member sees no project until added');

-- 12. Profiles are visible only to people who share a workspace.
select pg_temp.check((select count(*) from public.profiles) = 4, 'Sara sees her 4 colleagues (incl. herself)');
select pg_temp.login('e');
select pg_temp.check((select count(*) from public.profiles) = 1, 'outsider sees only himself');

\echo 'all foundation tests passed'
