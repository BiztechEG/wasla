-- Phase 3 review: assignee changes, edits that change nothing, deletes,
-- reopened projects, the read policy and the rate limit.

\set ON_ERROR_STOP on

-- Users: Omar (owner), Laila (lead of the project), Hany and Rana (in the
-- project), Yara (in the workspace, not the project).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000601', 'omar@example.com',  '{"full_name":"Omar"}'),
  ('00000000-0000-0000-0000-000000000602', 'laila@example.com', '{"full_name":"Laila"}'),
  ('00000000-0000-0000-0000-000000000603', 'hany@example.com',  '{"full_name":"Hany"}'),
  ('00000000-0000-0000-0000-000000000604', 'rana@example.com',  '{"full_name":"Rana"}'),
  ('00000000-0000-0000-0000-000000000605', 'yara@example.com',  '{"full_name":"Yara"}');

create temp table ctx (k text primary key, v text);
grant all on ctx to authenticated;

create function pg_temp.login(n int) returns void language sql as $$
  select set_config('role', 'authenticated', false),
         set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000' || n, false);
$$;

create function pg_temp.as_server() returns void language sql as $$
  select set_config('role', 'postgres', false),
         set_config('request.jwt.claim.sub', '', false);
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
create function pg_temp.path(n int, file text) returns text language sql as $$
  select pg_temp.v('ws') || '/' || pg_temp.uid(n) || '/' || file $$;
create function pg_temp.upload(n int, file text, size bigint) returns void language sql as $$
  insert into storage.objects (bucket_id, name, metadata)
  values ('files', pg_temp.path(n, file), jsonb_build_object('size', size)) $$;

-- Read as the server, whoever is logged in.
create function pg_temp.activity(task text) returns bigint language sql security definer as $$
  select count(*) from public.task_activity where task_id = pg_temp.v(task) $$;
create function pg_temp.writes(n int) returns bigint language sql security definer as $$
  select count(*) from public.task_writes where user_id = pg_temp.uid(n) $$;
create function pg_temp.pending(task text, what text) returns bigint language sql security definer as $$
  select count(*) from public.task_reminders
  where task_id = pg_temp.v(task) and kind = what and sent_at is null $$;
create function pg_temp.live_files(task text) returns bigint language sql security definer as $$
  select count(*) from public.files where task_id = pg_temp.v(task) and deleted_at is null $$;
create function pg_temp.n(key text) returns bigint language sql as $$
  select v::bigint from ctx where k = key $$;
-- The tasks the logged-in user may see, by the rule rather than the policy.
create function pg_temp.seen() returns bigint language sql security definer as $$
  select count(*) from public.tasks where public.can_see_task(id) $$;

select pg_temp.login(601);
insert into ctx values ('ws', public.create_company_workspace('Nile', 'eg', 'Nile HQ'));
insert into public.invites (workspace_id, email, role, invited_by) values
  (pg_temp.v('ws'), 'laila@example.com', 'member', auth.uid()),
  (pg_temp.v('ws'), 'hany@example.com',  'member', auth.uid()),
  (pg_temp.v('ws'), 'rana@example.com',  'member', auth.uid()),
  (pg_temp.v('ws'), 'yara@example.com',  'member', auth.uid());
do $$
begin
  for n in 602..605 loop
    perform pg_temp.login(n);
    perform public.accept_invite((select token from public.my_invites() limit 1));
  end loop;
end $$;

select pg_temp.login(601);
with p as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.v('ws'), 'Tower', auth.uid()) returning id
)
insert into ctx select 'p', id::text from p;
insert into public.project_members (project_id, user_id, role) values
  (pg_temp.v('p'), pg_temp.uid(602), 'lead'),
  (pg_temp.v('p'), pg_temp.uid(603), 'member'),
  (pg_temp.v('p'), pg_temp.uid(604), 'member');

-- 1. Someone who doesn't lead the project only adds or removes themselves.
select pg_temp.login(603);
insert into ctx values ('ta', public.create_task(pg_temp.v('p'), 'Pour the foundation', 'Level B2',
  p_due_at => now() + interval '3 days'));
select pg_temp.check(public.task_detail(pg_temp.v('ta')) ->> 'can_assign' = 'false',
  'a member is told they cannot assign others');
select pg_temp.login(602);
select pg_temp.check(public.task_detail(pg_temp.v('ta')) ->> 'can_assign' = 'true',
  'the lead is told they can');
select public.set_task_assignees(pg_temp.v('ta'), array[pg_temp.uid(603), pg_temp.uid(604)]);

select pg_temp.login(603);
select pg_temp.fails($$ select public.set_task_assignees(pg_temp.v('ta'), array[pg_temp.uid(603)]) $$,
  'not_allowed', 'the creator cannot take a colleague off their task');
select pg_temp.fails($$ select public.set_task_assignees(pg_temp.v('ta'),
    array[pg_temp.uid(603), pg_temp.uid(604), pg_temp.uid(601)]) $$,
  'not_allowed', 'nor add someone else');
select public.set_task_assignees(pg_temp.v('ta'), array[pg_temp.uid(604)]);
select public.set_task_assignees(pg_temp.v('ta'), array[pg_temp.uid(603), pg_temp.uid(604)]);
select pg_temp.check(
  (select jsonb_array_length(assignees) from public.my_tasks() where id = pg_temp.v('ta')) = 2,
  'but can step off and back on');

select pg_temp.login(602);
select public.set_task_assignees(pg_temp.v('ta'), array[pg_temp.uid(603)]);
select public.update_task(pg_temp.v('ta'), 'Pour the foundation, phase 2', 'Level B2',
  (select due_at from public.tasks where id = pg_temp.v('ta')), null, null, array[1440, 60]);
select pg_temp.login(604);
select pg_temp.check(not exists (select 1 from public.tasks where id = pg_temp.v('ta')),
  'someone taken off a private task no longer sees it');
select pg_temp.check(
  (select task_title from public.my_notifications()
   where task_id = pg_temp.v('ta') and kind = 'unassigned') = 'Pour the foundation',
  'but is told, under the title they knew');
select pg_temp.check(
  (select count(*) from public.my_notifications() where task_id = pg_temp.v('ta')) = 1,
  'and their other notifications about it are hidden');

-- Someone who has left the project doesn't block changing the others.
select pg_temp.login(602);
select public.set_task_assignees(pg_temp.v('ta'), array[pg_temp.uid(603), pg_temp.uid(604)]);
select pg_temp.login(601);
delete from public.project_members where project_id = pg_temp.v('p') and user_id = pg_temp.uid(604);
select pg_temp.login(602);
select public.set_task_assignees(pg_temp.v('ta'),
  array[pg_temp.uid(603), pg_temp.uid(604), pg_temp.uid(601)]);
select pg_temp.check(
  (select jsonb_array_length(assignees) from public.project_tasks(pg_temp.v('p'))
   where id = pg_temp.v('ta')) = 3,
  'a lead can change a task''s assignees while one of them has left the project');
select pg_temp.fails($$ select public.set_task_assignees(pg_temp.v('ta'), array[pg_temp.uid(603), pg_temp.uid(605)]) $$,
  'invalid_assignee', 'but only adds people in the project');
select public.set_task_assignees(pg_temp.v('ta'), array[pg_temp.uid(603)]);
select pg_temp.login(601);
insert into public.project_members (project_id, user_id, role) values
  (pg_temp.v('p'), pg_temp.uid(604), 'member');

-- 2. Saving a task unchanged does nothing.
select pg_temp.login(602);
insert into ctx values ('a0', pg_temp.activity('ta')), ('w0', pg_temp.writes(602));
select public.update_task(pg_temp.v('ta'), ' Pour the foundation, phase 2 ', 'Level B2',
  (select due_at from public.tasks where id = pg_temp.v('ta')), 'normal', null, array[60, 1440]);
select public.set_task_assignees(pg_temp.v('ta'), array[pg_temp.uid(603)]);
select pg_temp.check(pg_temp.activity('ta') = pg_temp.n('a0') and pg_temp.writes(602) = pg_temp.n('w0'),
  'saving a task unchanged logs nothing and doesn''t count toward the limit');

-- 3. The same status again is not a change; a new hold reason is.
select pg_temp.login(603);
select public.set_task_status(pg_temp.v('ta'), 'in_progress');
insert into ctx values ('a1', pg_temp.activity('ta'));
select public.set_task_status(pg_temp.v('ta'), 'in_progress');
select pg_temp.check(pg_temp.activity('ta') = pg_temp.n('a1'), 'setting the same status again is not logged');
select public.set_task_status(pg_temp.v('ta'), 'on_hold', 'Waiting for cement');
select public.set_task_status(pg_temp.v('ta'), 'on_hold', ' Waiting for cement ');
select pg_temp.check(pg_temp.activity('ta') = pg_temp.n('a1') + 1, 'nor is the same hold reason');
select public.set_task_status(pg_temp.v('ta'), 'on_hold', 'Waiting for steel');
select pg_temp.check(pg_temp.activity('ta') = pg_temp.n('a1') + 2
  and public.task_detail(pg_temp.v('ta')) ->> 'hold_reason' = 'Waiting for steel',
  'but a new hold reason is');
select public.set_task_status(pg_temp.v('ta'), 'in_progress');

-- 4. Reminders.
select pg_temp.login(602);
select public.add_task_reminder(pg_temp.v('ta'), now() + interval '18 months');
select pg_temp.check(jsonb_array_length(public.task_detail(pg_temp.v('ta')) -> 'reminders') = 1,
  'a reminder can be set a year and a half ahead');
select pg_temp.fails($$ select public.add_task_reminder(pg_temp.v('ta'), now() + interval '25 months') $$,
  'invalid_reminder', 'but not more than two years');
insert into ctx values ('tdone', public.create_task(pg_temp.v('p'), 'Hire a surveyor', null,
  array[pg_temp.uid(603)], now() + interval '1 day'));
select public.set_task_status(pg_temp.v('tdone'), 'done');
select pg_temp.fails($$ select public.nudge_task(pg_temp.v('tdone')) $$, 'not_allowed',
  'a finished task can''t be nudged');
select pg_temp.fails($$ select public.add_task_reminder(pg_temp.v('tdone'), now() + interval '1 hour') $$,
  'not_allowed', 'nor get a reminder');

-- 5. Reopening an archived project schedules its reminders again.
select pg_temp.as_server();
update public.task_reminders set remind_at = now() - interval '1 minute'
where task_id = pg_temp.v('ta') and kind in ('before', 'overdue') and sent_at is null;
select pg_temp.login(601);
update public.projects set status = 'archived' where id = pg_temp.v('p');
select pg_temp.as_server();
select public.process_task_reminders();
select pg_temp.check(pg_temp.pending('ta', 'overdue') = 0, 'reminders due while a project is archived are dropped');
select pg_temp.login(601);
update public.projects set status = 'active' where id = pg_temp.v('p');
select pg_temp.check(pg_temp.pending('ta', 'overdue') = 1 and pg_temp.pending('ta', 'before') = 2,
  'reopening the project schedules its tasks'' reminders again');

-- 6. Deleting a task takes its attachments and reminders and tells its people.
select pg_temp.login(602);
insert into ctx values ('tb', public.create_task(pg_temp.v('p'), 'Site photos', null,
  array[pg_temp.uid(603)], now() + interval '5 days'));
select pg_temp.login(603);
select pg_temp.upload(603, 'site.jpg', 5000);
insert into ctx values ('fb', public.add_task_attachment(pg_temp.v('tb'), pg_temp.path(603, 'site.jpg'),
  'site.jpg', 'image/jpeg', 0));
select pg_temp.check(not public.can_remove_object(pg_temp.path(603, 'site.jpg'))
  and pg_temp.live_files('tb') = 1 and pg_temp.pending('tb', 'overdue') = 1,
  'an attachment''s stored file is kept while its task is there');
select pg_temp.login(602);
select public.delete_task(pg_temp.v('tb'));
select pg_temp.check(pg_temp.live_files('tb') = 0 and pg_temp.pending('tb', 'overdue') = 0,
  'deleting a task removes its attachments and reminders');
select pg_temp.login(603);
select pg_temp.check(public.can_remove_object(pg_temp.path(603, 'site.jpg')),
  'so the uploader''s app can free the space');
select pg_temp.check(
  (select array_agg(task_title) from public.my_notifications()
   where task_id = pg_temp.v('tb') and kind = 'deleted') = array['Site photos'],
  'the assignee is told it was deleted');

-- 7. A deleted task is not found, whatever one tries.
select pg_temp.login(602);
select pg_temp.fails($$ select public.set_task_status(pg_temp.v('tb'), 'in_progress') $$, 'not_found',
  'a deleted task can''t be moved along');
select pg_temp.fails($$ select public.update_task(pg_temp.v('tb'), 'Again', null, null, null, null, null) $$,
  'not_found', 'nor edited');
select pg_temp.fails($$ select public.set_task_assignees(pg_temp.v('tb'), array[pg_temp.uid(603)]) $$,
  'not_found', 'nor reassigned');
select pg_temp.fails($$ select public.add_task_comment(pg_temp.v('tb'), 'Hello') $$, 'not_found',
  'nor commented on');
select pg_temp.fails($$ select public.delete_task(pg_temp.v('tb')) $$, 'not_found', 'nor deleted twice');

-- 8. Removing an attachment from the files tab changes its task too.
select pg_temp.login(603);
select pg_temp.upload(603, 'mix.pdf', 1000);
insert into ctx values ('fa', public.add_task_attachment(pg_temp.v('ta'), pg_temp.path(603, 'mix.pdf'),
  'mix.pdf', 'application/pdf', 0));
insert into ctx select 'ta_at', updated_at::text from public.tasks where id = pg_temp.v('ta');
select public.delete_file(pg_temp.v('fa'));
select pg_temp.check(
  (select updated_at from public.tasks where id = pg_temp.v('ta')) > (select v::timestamptz from ctx where k = 'ta_at'),
  'removing a task''s attachment updates the task');

-- 9. The table shows each person exactly the tasks they may see.
select pg_temp.login(602);
insert into ctx values ('tpub', public.create_task(pg_temp.v('p'), 'Safety briefing', null,
  array[pg_temp.uid(604)], null, 'normal', 'public'));
select pg_temp.login(604);
insert into ctx values ('tr', public.create_task(pg_temp.v('p'), 'Book the crane'));
create temp table seen (n int, policy bigint, rule bigint);
grant all on seen to authenticated;
do $$
begin
  for n in 601..605 loop
    perform pg_temp.login(n);
    insert into seen select n, (select count(*) from public.tasks), pg_temp.seen();
  end loop;
end $$;
select pg_temp.check(
  (select array_agg(policy order by n) from seen) = (select array_agg(rule order by n) from seen)
  and (select array_agg(rule order by n) from seen) = array[4, 4, 3, 2, 0]::bigint[],
  'the tasks table shows each person exactly the tasks they may see');

-- 10. A deactivated member loses their tasks.
select pg_temp.as_server();
update public.workspace_members set status = 'inactive'
where workspace_id = pg_temp.v('ws') and user_id = pg_temp.uid(604);
select pg_temp.login(604);
select pg_temp.check(not exists (select 1 from public.tasks) and not exists (select 1 from public.my_tasks()),
  'a deactivated member sees none of their tasks');
select pg_temp.fails($$ select public.task_detail(pg_temp.v('tr')) $$, 'not_found',
  'nor opens one they created');
select pg_temp.fails($$ select public.set_task_status(pg_temp.v('tr'), 'done') $$, 'not_allowed',
  'nor changes it');
select pg_temp.as_server();
update public.workspace_members set status = 'active'
where workspace_id = pg_temp.v('ws') and user_id = pg_temp.uid(604);

-- 11. Every kind of change counts toward the per-minute limit.
select pg_temp.login(602);
select pg_temp.fails($$
  do $do$ begin
    for i in 1..70 loop
      perform public.update_task(pg_temp.v('ta'), 'Pour the foundation, phase 2', 'Draft ' || i,
        null, null, null, array[1440, 60]);
    end loop;
  end $do$ $$,
  'too_many_requests', 'editing a task is rate limited');

reset role;
select 'all task review tests passed';
