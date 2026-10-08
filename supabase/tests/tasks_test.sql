-- Phase 3: tasks, who sees and changes them, reminders and notifications.

\set ON_ERROR_STOP on

-- Users: Mona (owner), Sara (lead of the project), Ahmed and Karim (in the
-- project), Dina (in the workspace, not the project).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000501', 'mona@example.com',  '{"full_name":"Mona"}'),
  ('00000000-0000-0000-0000-000000000502', 'sara@example.com',  '{"full_name":"Sara"}'),
  ('00000000-0000-0000-0000-000000000503', 'ahmed@example.com', '{"full_name":"Ahmed"}'),
  ('00000000-0000-0000-0000-000000000504', 'karim@example.com', '{"full_name":"Karim"}'),
  ('00000000-0000-0000-0000-000000000505', 'dina@example.com',  '{"full_name":"Dina"}');

create temp table ctx (k text primary key, v text);
grant all on ctx to authenticated;

create function pg_temp.login(n int) returns void language sql as $$
  select set_config('role', 'authenticated', false),
         set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000' || n, false);
$$;

-- Back to the server itself, as the scheduled job runs.
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
-- Notifications of a kind that user n has about a task, read as the server.
create function pg_temp.notes(n int, task text, what text) returns bigint
language sql security definer as $$
  select count(*) from public.notifications
  where user_id = pg_temp.uid(n) and task_id = pg_temp.v(task) and kind = what $$;

select pg_temp.login(501);
insert into ctx values ('ws', public.create_company_workspace('Delta', 'eg', 'Delta HQ'));
insert into public.invites (workspace_id, email, role, invited_by) values
  (pg_temp.v('ws'), 'sara@example.com',  'member', auth.uid()),
  (pg_temp.v('ws'), 'ahmed@example.com', 'member', auth.uid()),
  (pg_temp.v('ws'), 'karim@example.com', 'member', auth.uid()),
  (pg_temp.v('ws'), 'dina@example.com',  'member', auth.uid());
do $$
begin
  for n in 502..505 loop
    perform pg_temp.login(n);
    perform public.accept_invite((select token from public.my_invites() limit 1));
  end loop;
end $$;

select pg_temp.login(501);
with p as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.v('ws'), 'New branch', auth.uid()) returning id
)
insert into ctx select 'p', id::text from p;
insert into public.project_members (project_id, user_id, role) values
  (pg_temp.v('p'), pg_temp.uid(502), 'lead'),
  (pg_temp.v('p'), pg_temp.uid(503), 'member'),
  (pg_temp.v('p'), pg_temp.uid(504), 'member');
insert into ctx values ('pc', public.project_conversation(pg_temp.v('p')));

-- 1. A lead gives Ahmed a private task; who sees it.
select pg_temp.login(502);
insert into ctx values ('t1', public.create_task(
  pg_temp.v('p'), '  Review the plan  ', 'With the contractor',
  array[pg_temp.uid(503)], now() + interval '2 days'));
select pg_temp.check((select title from public.tasks where id = pg_temp.v('t1')) = 'Review the plan',
  'the title is trimmed');

select pg_temp.login(503);
select pg_temp.check(exists (select 1 from public.my_tasks() where id = pg_temp.v('t1')),
  'the assignee has it in my tasks');
select pg_temp.check(pg_temp.notes(503, 't1', 'assigned') = 1, 'the assignee is told');
select pg_temp.check(pg_temp.notes(502, 't1', 'assigned') = 0, 'the creator is not told about their own task');

select pg_temp.login(504);
select pg_temp.check(not exists (select 1 from public.project_tasks(pg_temp.v('p')) where id = pg_temp.v('t1')),
  'another project member does not see a private task');
select pg_temp.fails($$ select public.task_detail(pg_temp.v('t1')) $$, 'not_found',
  'nor can open it');
select pg_temp.check((select count(*) from public.tasks) = 0, 'nor read it from the table');

select pg_temp.login(501);
select pg_temp.check(exists (select 1 from public.project_tasks(pg_temp.v('p')) where id = pg_temp.v('t1')),
  'an admin sees every task in the project');

select pg_temp.login(505);
select pg_temp.check(not exists (select 1 from public.project_tasks(pg_temp.v('p'))),
  'someone outside the project sees none of its tasks');

-- 2. Members create tasks for themselves only.
select pg_temp.login(503);
insert into ctx values ('t_self', public.create_task(pg_temp.v('p'), 'Order samples'));
select pg_temp.check(
  (select assignees = jsonb_build_array(jsonb_build_object('id', pg_temp.uid(503), 'name', 'Ahmed'))
   from public.my_tasks() where id = pg_temp.v('t_self')),
  'a task without assignees goes to its creator');
select pg_temp.fails($$ select public.create_task(pg_temp.v('p'), 'For Karim', null, array[pg_temp.uid(504)]) $$,
  'not_allowed', 'a member cannot give someone else a task');

select pg_temp.login(502);
select pg_temp.fails($$ select public.create_task(pg_temp.v('p'), 'For Dina', null, array[pg_temp.uid(505)]) $$,
  'invalid_assignee', 'a task only goes to people in the project');
select pg_temp.fails($$ select public.create_task(pg_temp.v('p'), 'Too many', p_remind_before => array[1, 60]) $$,
  'invalid_reminder', 'reminder times are checked');

-- 3. A public task: everyone in the project sees it, comments stay with its parties.
select pg_temp.login(502);
insert into ctx values ('t2', public.create_task(
  pg_temp.v('p'), 'Get the permits', null, array[pg_temp.uid(503)],
  now() + interval '3 days', 'urgent', 'public'));

select pg_temp.login(503);
select public.add_task_comment(pg_temp.v('t2'), 'Called the office');

select pg_temp.login(504);
select pg_temp.check(exists (select 1 from public.project_tasks(pg_temp.v('p')) where id = pg_temp.v('t2')),
  'a project member sees a public task');
select pg_temp.check(
  (select not exists (select 1 from jsonb_array_elements(public.task_detail(pg_temp.v('t2')) -> 'activity') a
                      where a ->> 'kind' = 'comment')),
  'but not its comments');
select pg_temp.check(not (public.task_detail(pg_temp.v('t2')) ->> 'is_party')::boolean,
  'and is not one of its parties');
select pg_temp.fails($$ select public.add_task_comment(pg_temp.v('t2'), 'hi') $$, 'not_allowed',
  'nor comment on it');
select pg_temp.fails($$ select public.set_task_status(pg_temp.v('t2'), 'in_progress') $$, 'not_allowed',
  'nor move it along');
select pg_temp.check((select count(*) from public.tasks) = 1, 'and reads only it from the table');

select pg_temp.login(501);
select pg_temp.check(
  (select exists (select 1 from jsonb_array_elements(public.task_detail(pg_temp.v('t2')) -> 'activity') a
                  where a ->> 'kind' = 'comment' and a ->> 'body' = 'Called the office')),
  'an admin reads the comments');
select pg_temp.check(pg_temp.notes(502, 't2', 'comment') = 1, 'the creator is told about a comment');

-- 4. Status: the assignee moves it along, the creator closes it.
select pg_temp.login(503);
select public.set_task_status(pg_temp.v('t1'), 'in_progress');
select pg_temp.fails($$ select public.set_task_status(pg_temp.v('t1'), 'on_hold') $$, 'reason_required',
  'putting a task on hold needs a reason');
select public.set_task_status(pg_temp.v('t1'), 'on_hold', 'Waiting for the drawings');
select pg_temp.check((select hold_reason from public.tasks where id = pg_temp.v('t1')) = 'Waiting for the drawings',
  'the reason is kept');
select pg_temp.fails($$ select public.set_task_status(pg_temp.v('t1'), 'done') $$, 'not_allowed',
  'the assignee cannot mark it done');
select public.set_task_status(pg_temp.v('t1'), 'review');
select pg_temp.check((select hold_reason is null from public.tasks where id = pg_temp.v('t1')),
  'the reason goes once it moves on');
select pg_temp.check(pg_temp.notes(502, 't1', 'status') = 3, 'the creator hears of each change');

select pg_temp.login(502);
select public.set_task_status(pg_temp.v('t1'), 'done');
select pg_temp.check((select done_at is not null from public.tasks where id = pg_temp.v('t1')),
  'the creator marks it done');
select pg_temp.check(pg_temp.notes(503, 't1', 'status') = 1, 'the assignee hears it is done');

select pg_temp.login(503);
select pg_temp.fails($$ select public.set_task_status(pg_temp.v('t1'), 'in_progress') $$, 'not_allowed',
  'the assignee cannot reopen it');
select public.set_task_status(pg_temp.v('t_self'), 'done');
select pg_temp.check((select status = 'done' from public.tasks where id = pg_temp.v('t_self')),
  'one closes a task one gave oneself');

-- 5. Editing is for the creator, leads and admins.
select pg_temp.login(503);
select pg_temp.fails(
  $$ select public.update_task(pg_temp.v('t2'), 'Renamed', null, null, 'normal', 'public', null) $$,
  'not_allowed', 'an assignee cannot change what the task is');

select pg_temp.login(502);
select public.update_task(pg_temp.v('t2'), 'Get the permits', 'From the municipality',
  now() + interval '5 days', 'urgent', 'public', array[60]);
select pg_temp.check(pg_temp.notes(503, 't2', 'due_changed') = 1, 'a new due time is announced');
select pg_temp.check(
  (select exists (select 1 from jsonb_array_elements(public.task_detail(pg_temp.v('t2')) -> 'activity') a
                  where a ->> 'kind' = 'due' and (a ->> 'new_value')::timestamptz > now() + interval '4 days')),
  'and recorded');

select public.set_task_assignees(pg_temp.v('t2'), array[pg_temp.uid(503), pg_temp.uid(504)]);
select pg_temp.check(pg_temp.notes(504, 't2', 'assigned') = 1, 'someone added is told');
select pg_temp.check(pg_temp.notes(503, 't2', 'assigned') = 1, 'someone already on it is not told again');

select pg_temp.login(504);
select pg_temp.check((public.task_detail(pg_temp.v('t2')) ->> 'is_party')::boolean,
  'an assignee is one of its parties');

-- 6. Attachments follow the task.
select pg_temp.login(503);
select pg_temp.upload(503, 'plan.pdf', 2000);
select public.add_task_attachment(pg_temp.v('t1'), pg_temp.path(503, 'plan.pdf'), 'plan.pdf', 'application/pdf', 0);
select pg_temp.upload(503, 'permit.pdf', 3000);
insert into ctx values ('f2', public.add_task_attachment(pg_temp.v('t2'), pg_temp.path(503, 'permit.pdf'),
  'permit.pdf', 'application/pdf', 0));
select pg_temp.check(
  (select (f ->> 'size_bytes')::bigint = 3000
   from jsonb_array_elements(public.task_detail(pg_temp.v('t2')) -> 'files') f
   where (f ->> 'id')::uuid = pg_temp.v('f2')),
  'an attachment keeps the stored size');

select pg_temp.login(505);
select pg_temp.check(not public.can_read_object(pg_temp.path(503, 'permit.pdf')),
  'someone outside the project cannot download it');

select pg_temp.login(504);
select pg_temp.check(exists (select 1 from public.project_files(pg_temp.v('p')) where name = 'permit.pdf'),
  'a public task''s attachment is in the project files');
select pg_temp.check(not exists (select 1 from public.project_files(pg_temp.v('p')) where name = 'plan.pdf'),
  'a private task''s is not, for someone who cannot see the task');
select pg_temp.check(not public.can_read_object(pg_temp.path(503, 'plan.pdf')),
  'nor can they download it');

-- 7. Reminders are lined up with the due time.
select pg_temp.login(502);
insert into ctx values ('t3', public.create_task(
  pg_temp.v('p'), 'Send the quote', null, array[pg_temp.uid(503)], now() + interval '2 days'));
select pg_temp.as_server();
select pg_temp.check(
  (select count(*) filter (where kind = 'before') = 2 and count(*) filter (where kind = 'overdue') = 1
   from public.task_reminders where task_id = pg_temp.v('t3')),
  'a day and an hour before, and when it is late');

select pg_temp.login(502);
select public.update_task(pg_temp.v('t3'), 'Send the quote', null, null, 'normal', 'private', null);
select pg_temp.as_server();
select pg_temp.check(not exists (select 1 from public.task_reminders where task_id = pg_temp.v('t3')),
  'no due time, no reminders');

select pg_temp.login(502);
select public.update_task(pg_temp.v('t3'), 'Send the quote', null, now() + interval '30 minutes',
  'normal', 'private', null);
select pg_temp.as_server();
select pg_temp.check(
  (select count(*) filter (where kind = 'before') = 0 and count(*) filter (where kind = 'overdue') = 1
   from public.task_reminders where task_id = pg_temp.v('t3')),
  'reminders that would already be past are skipped');

-- The due time arrives.
update public.tasks set due_at = now() - interval '1 minute' where id = pg_temp.v('t3');
update public.task_reminders set remind_at = now() - interval '1 minute' where task_id = pg_temp.v('t3');
select pg_temp.check(public.process_task_reminders() = 1, 'the job sends what is due');
select pg_temp.check(pg_temp.notes(503, 't3', 'overdue') = 1 and pg_temp.notes(502, 't3', 'overdue') = 1,
  'a late task is announced to the assignee and the creator');
select pg_temp.check(public.process_task_reminders() = 0, 'and only once');

-- A reminder before the due time, for the assignees.
select pg_temp.login(502);
insert into ctx values ('t4', public.create_task(
  pg_temp.v('p'), 'Book the venue', null, array[pg_temp.uid(503)], now() + interval '2 days'));
select pg_temp.as_server();
update public.task_reminders set remind_at = now() - interval '1 minute'
where task_id = pg_temp.v('t4') and kind = 'before';
select public.process_task_reminders();
select pg_temp.check(pg_temp.notes(503, 't4', 'due_soon') = 2 and pg_temp.notes(502, 't4', 'due_soon') = 0,
  'the assignee is reminded before the due time');

-- Finished tasks are not chased.
select pg_temp.login(502);
insert into ctx values ('t5', public.create_task(
  pg_temp.v('p'), 'Print the badges', null, array[pg_temp.uid(503)], now() + interval '2 days'));
select public.set_task_status(pg_temp.v('t5'), 'done');
select pg_temp.as_server();
select pg_temp.check(not exists (select 1 from public.task_reminders where task_id = pg_temp.v('t5') and sent_at is null),
  'a finished task has no reminders left');

-- 8. Custom reminders and "remind them".
select pg_temp.login(503);
select pg_temp.fails($$ select public.add_task_reminder(pg_temp.v('t4'), now() + interval '1 hour') $$,
  'not_allowed', 'an assignee cannot add reminders');
select pg_temp.login(502);
select pg_temp.fails($$ select public.add_task_reminder(pg_temp.v('t4'), now() - interval '1 hour') $$,
  'invalid_reminder', 'a reminder must be in the future');
insert into ctx values ('r1', public.add_task_reminder(pg_temp.v('t4'), now() + interval '1 hour'));
select pg_temp.check(jsonb_array_length(public.task_detail(pg_temp.v('t4')) -> 'reminders') = 1,
  'the creator sees the reminder');
select pg_temp.as_server();
update public.task_reminders set remind_at = now() - interval '1 minute' where id = pg_temp.v('r1');
select public.process_task_reminders();
select pg_temp.check(pg_temp.notes(503, 't4', 'reminder') = 1, 'a custom reminder reaches the assignee');

select pg_temp.login(502);
select public.nudge_task(pg_temp.v('t4'));
select pg_temp.check(pg_temp.notes(503, 't4', 'nudge') = 1, '"remind them" reaches the assignee');
select pg_temp.fails($$ select public.nudge_task(pg_temp.v('t4')) $$, 'too_many_requests',
  'once an hour');
select pg_temp.login(504);
select pg_temp.fails($$ select public.nudge_task(pg_temp.v('t2')) $$, 'not_allowed',
  'an assignee who did not create it cannot nudge the others');

-- 9. Notifications are one's own.
select pg_temp.login(503);
select pg_temp.check(
  (select count(*) > 0 and bool_and(task_title is not null) from public.my_notifications()),
  'one lists one''s notifications with their task');
select pg_temp.check(
  (select count(*) = (select count(*) from public.notifications where user_id = pg_temp.uid(503))
   from public.notifications),
  'and reads only one''s own from the table');
select public.mark_notifications_read();
select pg_temp.check(not exists (select 1 from public.my_notifications() where read_at is null),
  'marking all read');
select pg_temp.fails($$ select * from public.task_activity $$, '42501', 'updates are not readable directly');

-- 10. Follow-up: leads see their projects' tasks, members none.
select pg_temp.login(502);
select pg_temp.check(exists (select 1 from public.managed_tasks(pg_temp.v('ws')) where id = pg_temp.v('t_self')),
  'a lead follows a member''s own private task');
select pg_temp.login(504);
select pg_temp.check(not exists (select 1 from public.managed_tasks(pg_temp.v('ws'))),
  'a member follows nothing');

-- 11. Tasks from messages one can read.
select pg_temp.login(503);
insert into ctx values ('m1', public.send_message(pg_temp.v('pc'), 'Please check the drawings'));
insert into ctx values ('t6', public.create_task(pg_temp.v('p'), 'Check the drawings',
  p_source_message => pg_temp.v('m1')));
select pg_temp.check(
  (public.task_detail(pg_temp.v('t6')) ->> 'source_conversation_id')::uuid = pg_temp.v('pc'),
  'a task made from a message links back to its chat');
select pg_temp.login(502);
insert into ctx values ('dm', public.open_direct(pg_temp.v('ws'), pg_temp.uid(504)));
insert into ctx values ('m2', public.send_message(pg_temp.v('dm'), 'Between us'));
select pg_temp.login(503);
select pg_temp.fails($$ select public.create_task(pg_temp.v('p'), 'Snoop', p_source_message => pg_temp.v('m2')) $$,
  'invalid_message', 'nor from someone else''s private chat');

-- 12. Closed projects freeze their tasks.
select pg_temp.login(501);
update public.projects set status = 'archived' where id = pg_temp.v('p');
select pg_temp.login(503);
select pg_temp.fails($$ select public.set_task_status(pg_temp.v('t2'), 'in_progress') $$, 'project_closed',
  'an archived project''s tasks are read-only');
select pg_temp.fails($$ select public.create_task(pg_temp.v('p'), 'Late idea') $$, 'project_closed',
  'and get no new ones');
select pg_temp.check(not exists (select 1 from public.my_tasks()), 'and leave my tasks');
select pg_temp.as_server();
update public.task_reminders set remind_at = now() - interval '1 minute'
where task_id = pg_temp.v('t2') and sent_at is null;
select pg_temp.check(public.process_task_reminders() = 0, 'and stop reminding');
select pg_temp.login(501);
update public.projects set status = 'active' where id = pg_temp.v('p');

-- 13. Deleting.
select pg_temp.login(503);
select pg_temp.fails($$ select public.delete_task(pg_temp.v('t4')) $$, 'not_allowed',
  'an assignee cannot delete a task');
select pg_temp.login(502);
select public.delete_task(pg_temp.v('t4'));
select pg_temp.login(503);
select pg_temp.check(not exists (select 1 from public.my_tasks() where id = pg_temp.v('t4')),
  'a deleted task leaves my tasks');
select pg_temp.fails($$ select public.task_detail(pg_temp.v('t4')) $$, 'not_found', 'and cannot be opened');
select pg_temp.check(
  (select array_agg(kind) from public.my_notifications() where task_id = pg_temp.v('t4')) = array['deleted'],
  'its notifications give way to one saying it was deleted');

-- 14. Someone who leaves the project loses its tasks.
select pg_temp.login(501);
delete from public.project_members where project_id = pg_temp.v('p') and user_id = pg_temp.uid(504);
select pg_temp.login(504);
select pg_temp.check(not exists (select 1 from public.my_tasks()), 'a former member keeps no tasks');
select pg_temp.fails($$ select public.task_detail(pg_temp.v('t2')) $$, 'not_found',
  'nor opens one assigned to them');

-- 15. Changes are limited per minute.
select pg_temp.login(503);
select pg_temp.fails($$
  do $do$ begin
    for i in 1..70 loop perform public.add_task_comment(pg_temp.v('t2'), 'note ' || i); end loop;
  end $do$ $$,
  'too_many_requests', 'task changes are rate limited');

reset role;
select 'all task tests passed';
