-- Recurring tasks and task templates.

\set ON_ERROR_STOP on

-- Users: Omar (owner), Laila (lead of the project), Hany and Rana (in the
-- project), Yara (in the workspace, not the project).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000971', 'omar3@example.com',  '{"full_name":"Omar"}'),
  ('00000000-0000-0000-0000-000000000972', 'laila3@example.com', '{"full_name":"Laila"}'),
  ('00000000-0000-0000-0000-000000000973', 'hany3@example.com',  '{"full_name":"Hany"}'),
  ('00000000-0000-0000-0000-000000000974', 'rana3@example.com',  '{"full_name":"Rana"}'),
  ('00000000-0000-0000-0000-000000000975', 'yara3@example.com',  '{"full_name":"Yara"}');

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

select pg_temp.login(971);
insert into ctx values ('ws', public.create_company_workspace('Luxor', 'eg', 'Luxor Office'));
insert into public.invites (workspace_id, email, role, invited_by) values
  (pg_temp.v('ws'), 'laila3@example.com', 'member', auth.uid()),
  (pg_temp.v('ws'), 'hany3@example.com',  'member', auth.uid()),
  (pg_temp.v('ws'), 'rana3@example.com',  'member', auth.uid()),
  (pg_temp.v('ws'), 'yara3@example.com',  'member', auth.uid());
do $$
begin
  for n in 972..975 loop
    perform pg_temp.login(n);
    perform public.accept_invite((select token from public.my_invites() limit 1));
  end loop;
end $$;

select pg_temp.login(971);
with p as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.v('ws'), 'Hotel', auth.uid()) returning id
)
insert into ctx select 'p', id::text from p;
insert into public.project_members (project_id, user_id, role) values
  (pg_temp.v('p'), pg_temp.uid(972), 'lead'),
  (pg_temp.v('p'), pg_temp.uid(973), 'member'),
  (pg_temp.v('p'), pg_temp.uid(974), 'member');


reset role;
create function pg_temp.task(key text) returns public.tasks language sql security definer as $$
  select * from public.tasks where id = pg_temp.v(key) $$;
create function pg_temp.next_of(key text) returns uuid language sql security definer as $$
  select repeat_next from public.tasks where id = pg_temp.v(key) $$;
create function pg_temp.assignees(t uuid) returns uuid[] language sql security definer as $$
  select array_agg(user_id order by user_id) from public.task_assignees where task_id = t $$;

-- 1. Repeating needs a due time, and only the task's editors set it.
select pg_temp.login(972);
insert into ctx values ('nodue', public.create_task(pg_temp.v('p'), 'Clean the site'));
select pg_temp.fails(format('select public.set_task_repeat(%L, %L)', pg_temp.v('nodue'), 'weekly'),
  'due_required', 'a task without a due time cannot repeat');
insert into ctx values ('weekly', public.create_task(pg_temp.v('p'), 'Weekly report', 'Send it Thursday',
  array[pg_temp.uid(973), pg_temp.uid(974)], now() + interval '1 day'));
select pg_temp.fails(format('select public.set_task_repeat(%L, %L)', pg_temp.v('weekly'), 'yearly'),
  'invalid_repeat', 'only daily, weekly or monthly');
select pg_temp.login(973);
select pg_temp.fails(format('select public.set_task_repeat(%L, %L)', pg_temp.v('weekly'), 'weekly'),
  'not_allowed', 'an assignee who did not create it cannot make it repeat');
select pg_temp.login(972);
select public.set_task_repeat(pg_temp.v('weekly'), 'weekly');
select pg_temp.check(public.task_detail(pg_temp.v('weekly')) ->> 'repeat' = 'weekly',
  'the task says how it repeats');

-- 2. Done: the next one appears a week on, for the same people.
select public.set_task_status(pg_temp.v('weekly'), 'done');
select pg_temp.check(pg_temp.next_of('weekly') is not null, 'finishing it makes the next one');
insert into ctx values ('weekly2', pg_temp.next_of('weekly')::text);
select pg_temp.check(
  (select t.due_at = (pg_temp.task('weekly')).due_at + interval '7 days'
          and t.status = 'new' and t.repeat = 'weekly' and t.title = 'Weekly report'
          and t.description = 'Send it Thursday' and t.created_by = pg_temp.uid(972)
   from pg_temp.task('weekly2') t),
  'a week later, with the same title, details and creator');
select pg_temp.check(pg_temp.assignees(pg_temp.v('weekly2')) = array[pg_temp.uid(973), pg_temp.uid(974)],
  'and the same people');
select pg_temp.login(973);
select pg_temp.check(
  (select count(*) from public.my_notifications() where task_id = pg_temp.v('weekly2') and kind = 'assigned') = 1,
  'who are told about it');
select pg_temp.login(972);
select public.set_task_status(pg_temp.v('weekly'), 'in_progress');
select public.set_task_status(pg_temp.v('weekly'), 'done');
select pg_temp.check(
  (select count(*) from public.tasks where title = 'Weekly report' and deleted_at is null) = 2,
  'reopening and finishing it again does not make another');

-- 3. Not done in time: the next one still comes when the due time passes.
insert into ctx values ('daily', public.create_task(pg_temp.v('p'), 'Safety walk', null,
  null, now() - interval '3 days 2 hours'));
select public.set_task_repeat(pg_temp.v('daily'), 'daily');
select pg_temp.as_server();
select pg_temp.check(public.process_recurring_tasks() >= 1, 'the job makes the overdue one''s next');
select pg_temp.check(public.process_recurring_tasks() = 0, 'and only once');
select pg_temp.check(
  (select due_at > now() and due_at <= now() + interval '1 day'
   from public.tasks where id = pg_temp.next_of('daily')),
  'skipping days already gone, so it is due within a day');
select pg_temp.check(
  (select count(*) from public.task_reminders where task_id = pg_temp.next_of('daily') and kind = 'overdue') = 1,
  'with its reminders lined up');

-- A closed project stops its tasks repeating.
select pg_temp.login(972);
insert into ctx values ('closed', public.create_task(pg_temp.v('p'), 'Monthly invoice', null,
  null, now() - interval '1 hour'));
select public.set_task_repeat(pg_temp.v('closed'), 'monthly');
select pg_temp.as_server();
update public.projects set status = 'closed' where id = pg_temp.v('p');
select public.process_recurring_tasks();
select pg_temp.check(pg_temp.next_of('closed') is null, 'nothing repeats in a closed project');
update public.projects set status = 'active' where id = pg_temp.v('p');

-- Stopping it: the next due time passes with nothing new.
select pg_temp.login(972);
select public.set_task_repeat(pg_temp.v('closed'), null);
select pg_temp.as_server();
select public.process_recurring_tasks();
select pg_temp.check(pg_temp.next_of('closed') is null, 'a task that stopped repeating makes no more');

-- 4. Templates: leads and admins keep them, everyone in the workspace uses them.
select pg_temp.login(973);
select pg_temp.fails(format('select public.save_task_template(%L, %L, %L)', pg_temp.v('ws'), 'Opening',
    '[{"title":"x"}]'), 'not_allowed', 'a member who leads nothing cannot save a template');
select pg_temp.login(972);
insert into ctx values ('tpl', public.save_task_template(pg_temp.v('ws'), ' New branch ',
  '[{"title":"Rent the place","due_in_days":3,"priority":"high"},
    {"title":"  "},
    {"title":"Hire staff","description":"Two cashiers","due_in_days":"x","priority":"boss"},
    "junk"]'::jsonb));
select pg_temp.check(
  (select name = 'New branch' and jsonb_array_length(items) = 2
          and items -> 1 ->> 'priority' = 'normal' and not (items -> 1 ? 'due_in_days')
   from public.task_templates(pg_temp.v('ws')) where id = pg_temp.v('tpl')),
  'a template keeps only proper tasks');
select pg_temp.fails(format('select public.save_task_template(%L, %L, %L)', pg_temp.v('ws'), 'Empty',
    '[{"title":" "}]'), 'invalid_template', 'a template needs a task');

-- Hany adds it to the project: the tasks are his.
select pg_temp.login(973);
select pg_temp.fails(format('select public.apply_task_template(%L, %L, %L)', pg_temp.v('tpl'),
    pg_temp.v('p'), array[pg_temp.uid(974)]), 'not_allowed',
  'someone who leads nothing cannot give a template''s tasks to others');
select pg_temp.check(public.apply_task_template(pg_temp.v('tpl'), pg_temp.v('p'),
    null, date_trunc('day', now()) + interval '15 hours') = 2,
  'a template adds its tasks');
select pg_temp.check(
  (select count(*) from public.tasks t
   where t.project_id = pg_temp.v('p') and t.title in ('Rent the place', 'Hire staff')
     and t.created_by = pg_temp.uid(973)
     and pg_temp.assignees(t.id) = array[pg_temp.uid(973)]) = 2,
  'for himself');
select pg_temp.check(
  (select due_at = date_trunc('day', now()) + interval '3 days 15 hours' and priority = 'high'
   from public.tasks where title = 'Rent the place'),
  'due the template''s days later, with its priority');
select pg_temp.fails(format('select public.delete_task_template(%L)', pg_temp.v('tpl')),
  'not_allowed', 'only its author or an admin removes a template');

-- Yara isn't in the project.
select pg_temp.login(975);
select pg_temp.check((select count(*) from public.task_templates(pg_temp.v('ws'))) = 1,
  'everyone in the workspace sees its templates');
select pg_temp.fails(format('select public.apply_task_template(%L, %L)', pg_temp.v('tpl'), pg_temp.v('p')),
  'not_allowed', 'but cannot add them to a project they are not in');

select pg_temp.login(971);
select public.delete_task_template(pg_temp.v('tpl'));
select pg_temp.check((select count(*) from public.task_templates(pg_temp.v('ws'))) = 0,
  'an admin removes a template');

reset role;
select 'all recurring and template tests passed';
