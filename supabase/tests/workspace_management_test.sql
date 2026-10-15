-- Managing workspaces: rename, leave, delete (hidden and locked), restore and
-- the purge 30 days later.

\set ON_ERROR_STOP on

-- Users: Nour (company owner), Adel (admin), Basma (member), Karim (outsider,
-- later invited), Lina (second owner).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000981', 'nour@example.com',  '{"full_name":"Nour"}'),
  ('00000000-0000-0000-0000-000000000982', 'adel@example.com',  '{"full_name":"Adel"}'),
  ('00000000-0000-0000-0000-000000000983', 'basma@example.com', '{"full_name":"Basma"}'),
  ('00000000-0000-0000-0000-000000000984', 'karim@example.com', '{"full_name":"Karim"}'),
  ('00000000-0000-0000-0000-000000000985', 'lina@example.com',  '{"full_name":"Lina"}');

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
  select ('00000000-0000-0000-0000-000000000' || n)::uuid $$;

select pg_temp.login(981);
insert into ctx values ('ws', public.create_company_workspace('Nile', 'eg', 'Nile Ops'));
update public.workspaces set discoverable = true where id = pg_temp.v('ws');
insert into public.invites (workspace_id, email, role, invited_by) values
  (pg_temp.v('ws'), 'adel@example.com',  'admin',  auth.uid()),
  (pg_temp.v('ws'), 'basma@example.com', 'member', auth.uid()),
  (pg_temp.v('ws'), 'lina@example.com',  'admin',  auth.uid());
do $$
begin
  for n in 982..985 loop
    continue when n = 984;
    perform pg_temp.login(n);
    perform public.accept_invite((select token from public.my_invites() limit 1));
  end loop;
end $$;

select pg_temp.login(981);
with p as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.v('ws'), 'Port', auth.uid()) returning id
)
insert into ctx select 'p', id::text from p;
insert into public.project_members (project_id, user_id, role) values
  (pg_temp.v('p'), pg_temp.uid(983), 'member');
insert into ctx values ('pc', public.project_conversation(pg_temp.v('p')));
select public.send_message(pg_temp.v('pc'), 'Hello team');
insert into ctx values ('task', public.create_task(pg_temp.v('p'), 'Load the ship', null,
  array[pg_temp.uid(983)], now() + interval '1 hour', 'normal', 'private', array[30]));
insert into public.invites (workspace_id, email, role, invited_by) values
  (pg_temp.v('ws'), 'karim@example.com', 'member', auth.uid());

-- 1. Renaming: admins yes, members no.
select pg_temp.login(982);
update public.workspaces set name = 'Nile Operations' where id = pg_temp.v('ws');
select pg_temp.check((select name from public.workspaces where id = pg_temp.v('ws')) = 'Nile Operations',
  'an admin renames the workspace');
select pg_temp.login(983);
update public.workspaces set name = 'Mine' where id = pg_temp.v('ws');
reset role;
select pg_temp.check((select name from public.workspaces where id = pg_temp.v('ws')) = 'Nile Operations',
  'a member cannot rename it');

-- 2. Leaving.
select pg_temp.login(984);
select pg_temp.fails($$select public.leave_workspace(pg_temp.v('ws'))$$, 'not_allowed',
  'an outsider cannot leave');
select pg_temp.login(985);
select public.leave_workspace(pg_temp.v('ws'));
reset role;
select pg_temp.check(
  (select status from public.workspace_members
   where workspace_id = pg_temp.v('ws') and user_id = pg_temp.uid(985)) = 'inactive',
  'a member leaves the workspace');
select pg_temp.login(981);
select pg_temp.fails($$select public.leave_workspace(pg_temp.v('ws'))$$, 'last_owner',
  'the last owner cannot leave');

-- 3. Deleting: only an owner, and only with the name typed back.
select pg_temp.login(982);
select pg_temp.check(not public.can_delete_workspace(pg_temp.v('ws')), 'an admin may not delete');
select pg_temp.fails($$select public.delete_workspace(pg_temp.v('ws'), 'Nile Operations')$$,
  'not_allowed', 'an admin cannot delete the workspace');
select pg_temp.login(981);
select pg_temp.check(public.can_delete_workspace(pg_temp.v('ws')), 'the owner may delete');
select pg_temp.fails($$select public.delete_workspace(pg_temp.v('ws'), 'Nile')$$,
  'name_mismatch', 'a wrong name does not delete');
select public.delete_workspace(pg_temp.v('ws'), '  Nile Operations ');

-- 4. Once deleted it is hidden and locked for everyone.
select pg_temp.check(not exists (select 1 from public.workspaces where id = pg_temp.v('ws')),
  'the owner no longer sees the workspace');
select pg_temp.check(not public.is_workspace_member(pg_temp.v('ws')), 'nobody is a member any more');
select pg_temp.check(not exists (select 1 from public.projects where id = pg_temp.v('p')),
  'its projects are hidden');
select pg_temp.check(not exists (select 1 from public.messages where conversation_id = pg_temp.v('pc')),
  'its messages are hidden');
select pg_temp.check((select count(*) from public.my_deleted_workspaces()) = 1,
  'the owner can still find it to restore');
select pg_temp.check(
  (select purge_at - deleted_at from public.my_deleted_workspaces()) = interval '30 days',
  'it is kept for 30 days');
select pg_temp.login(983);
select pg_temp.check(not exists (select 1 from public.tasks where id = pg_temp.v('task')),
  'the assignee no longer sees its task');
select pg_temp.check(not exists (select 1 from public.my_tasks()), 'nor in my tasks');
select pg_temp.check(not exists (select 1 from public.my_deleted_workspaces()),
  'a member cannot restore it');
select pg_temp.fails($$select public.send_message(pg_temp.v('pc'), 'Still here?')$$, 'not_allowed',
  'nobody can write in it');
select pg_temp.check(not exists (select 1 from public.search_workspaces('Nile')), 'it is gone from search');
select pg_temp.login(984);
select pg_temp.check(not exists (select 1 from public.my_invites()), 'pending invites are cancelled');
select pg_temp.fails($$select public.restore_workspace(pg_temp.v('ws'))$$, 'not_allowed',
  'an outsider cannot restore it');
reset role;
update public.task_reminders set remind_at = now() - interval '1 minute'
where task_id = pg_temp.v('task');
select pg_temp.check(public.process_task_reminders() = 0, 'its reminders are not sent');

-- 5. Restoring brings everything back.
select pg_temp.login(981);
select public.restore_workspace(pg_temp.v('ws'));
select pg_temp.check(exists (select 1 from public.workspaces where id = pg_temp.v('ws')),
  'the owner restores the workspace');
select pg_temp.login(983);
select pg_temp.check(exists (select 1 from public.tasks where id = pg_temp.v('task')),
  'its tasks are back');
select pg_temp.check(exists (select 1 from public.messages where conversation_id = pg_temp.v('pc')),
  'its messages are back');

-- 6. The purge removes it for good 30 days after deleting, not before.
select pg_temp.login(981);
select public.delete_workspace(pg_temp.v('ws'), 'Nile Operations');
reset role;
select pg_temp.check(public.purge_deleted_workspaces() = 0, 'a fresh delete is kept');
update public.workspaces set deleted_at = now() - interval '31 days' where id = pg_temp.v('ws');
select pg_temp.check(public.purge_deleted_workspaces() = 1, 'an old delete is purged');
select pg_temp.check(
  not exists (select 1 from public.workspaces where id = pg_temp.v('ws'))
  and not exists (select 1 from public.projects where id = pg_temp.v('p'))
  and not exists (select 1 from public.tasks where id = pg_temp.v('task'))
  and not exists (select 1 from public.messages where conversation_id = pg_temp.v('pc')),
  'with everything in it');
select pg_temp.check(not has_function_privilege('authenticated',
  'public.purge_deleted_workspaces()', 'execute'), 'only the scheduler purges');
