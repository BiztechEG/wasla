-- Attendance for managers: the team's day, workers without the app, roll
-- call, changes, reviews, corrections, reminders and extra workers on the
-- invoice.

\set ON_ERROR_STOP on

-- Users: Omar (owner), Laila (lead of Tower), Sami (in Tower), Hoda (member,
-- in no project), Tarek (outsider), Nour (lead of Mall).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000941', 'omar2@example.com',  '{"full_name":"Omar"}'),
  ('00000000-0000-0000-0000-000000000942', 'laila2@example.com', '{"full_name":"Laila"}'),
  ('00000000-0000-0000-0000-000000000943', 'sami2@example.com',  '{"full_name":"Sami"}'),
  ('00000000-0000-0000-0000-000000000944', 'hoda2@example.com',  '{"full_name":"Hoda"}'),
  ('00000000-0000-0000-0000-000000000945', 'tarek2@example.com', '{"full_name":"Tarek"}'),
  ('00000000-0000-0000-0000-000000000946', 'nour2@example.com',  '{"full_name":"Nour"}');

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
create function pg_temp.t(key text) returns timestamptz language sql as $$
  select v::timestamptz from ctx where k = key $$;
create function pg_temp.uid(n int) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-000000000' || n)::uuid $$;
create function pg_temp.person(n int) returns uuid language sql security definer as $$
  select id from public.attendance_people
  where workspace_id = pg_temp.v('ws') and user_id = pg_temp.uid(n) $$;
create function pg_temp.board(p uuid default null) returns jsonb language sql as $$
  select public.attendance_board(pg_temp.v('ws'), null, p) $$;
create function pg_temp.on_board(b jsonb, name text) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(b -> 'people') x where x ->> 'name' = name) $$;
create function pg_temp.entry(person uuid, at timestamptz) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('person', person, 'at', at)) $$;

select pg_temp.login(941);
insert into ctx values ('ws', public.create_company_workspace('Najd Two', 'sa', 'Najd Site'));
insert into public.invites (workspace_id, email, role, invited_by) values
  (pg_temp.v('ws'), 'laila2@example.com', 'member', auth.uid()),
  (pg_temp.v('ws'), 'sami2@example.com',  'member', auth.uid()),
  (pg_temp.v('ws'), 'hoda2@example.com',  'member', auth.uid()),
  (pg_temp.v('ws'), 'nour2@example.com',  'member', auth.uid());
do $$
declare
  n int;
begin
  foreach n in array array[942, 943, 944, 946] loop
    perform pg_temp.login(n);
    perform public.accept_invite((select token from public.my_invites() limit 1));
  end loop;
end $$;

select pg_temp.login(941);
with p as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.v('ws'), 'Tower', auth.uid()) returning id)
insert into ctx select 'tower', id::text from p;
with p as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.v('ws'), 'Mall', auth.uid()) returning id)
insert into ctx select 'mall', id::text from p;
insert into public.project_members (project_id, user_id, role) values
  (pg_temp.v('tower'), pg_temp.uid(942), 'lead'),
  (pg_temp.v('tower'), pg_temp.uid(943), 'member'),
  (pg_temp.v('mall'), pg_temp.uid(946), 'lead');

select pg_temp.login(942);
select pg_temp.fails($$select public.attendance_board(pg_temp.v('ws'))$$,
  'attendance_off', 'no board while attendance is off');

-- A shift that started two hours ago, no days off, HQ in Riyadh.
select pg_temp.login(941);
select public.enable_attendance(pg_temp.v('ws'), 'Morning');
insert into ctx values ('shift', public.attendance_setup(pg_temp.v('ws')) ->> 'default_shift_id');
select public.save_attendance_shift(pg_temp.v('ws'), pg_temp.v('shift'), 'Morning',
  ((now() at time zone 'Asia/Riyadh') - interval '2 hours')::time,
  ((now() at time zone 'Asia/Riyadh') + interval '6 hours')::time, 15);
select public.save_attendance_settings(pg_temp.v('ws'), true, '{}', false, true, true,
  pg_temp.v('shift'), null, null, null, null);
insert into ctx values ('hq', public.save_attendance_site(pg_temp.v('ws'), null, 'HQ', 24.7136, 46.6753, 150));
insert into ctx values ('start', (public.attendance_today(pg_temp.v('ws')) -> 'shift' ->> 'start_at'));

-- 1. Who manages whom.
select pg_temp.check((public.attendance_today(pg_temp.v('ws')) ->> 'is_manager')::boolean,
  'owners manage attendance');
select pg_temp.check(jsonb_array_length(pg_temp.board() -> 'people') = 5,
  'the owner sees every member, even those who never checked in');
select pg_temp.login(942);
select pg_temp.check((public.attendance_today(pg_temp.v('ws')) ->> 'is_manager')::boolean,
  'project leads manage attendance');
select pg_temp.check(pg_temp.on_board(pg_temp.board(), 'Sami')
  and pg_temp.on_board(pg_temp.board(), 'Laila')
  and not pg_temp.on_board(pg_temp.board(), 'Hoda')
  and not pg_temp.on_board(pg_temp.board(), 'Nour'),
  'a lead sees the people of their project only');
select pg_temp.check(jsonb_array_length(pg_temp.board() -> 'projects') = 1,
  'a lead filters by their own projects');
select pg_temp.login(944);
select pg_temp.check(not (public.attendance_today(pg_temp.v('ws')) ->> 'is_manager')::boolean,
  'members do not manage attendance');
select pg_temp.fails($$select pg_temp.board()$$, 'not_allowed', 'members have no board');
select pg_temp.login(945);
select pg_temp.fails($$select pg_temp.board()$$, 'not_allowed', 'outsiders have no board');

-- 2. Workers without the app.
select pg_temp.login(942);
insert into ctx values ('ali', public.save_attendance_worker(pg_temp.v('ws'), null, ' Ali ', 'Mason',
  '0100', 'W-1', pg_temp.v('tower'), pg_temp.v('hq'), null));
select pg_temp.fails($$select public.save_attendance_worker(pg_temp.v('ws'), null, 'Kamal', null, null,
  null, null, null, null)$$, 'not_allowed', 'a lead must add workers to one of their projects');
select pg_temp.fails($$select public.save_attendance_worker(pg_temp.v('ws'), null, 'Kamal', null, null,
  null, pg_temp.v('mall'), null, null)$$, 'not_allowed', 'not to another lead''s project');
select pg_temp.fails($$select public.save_attendance_worker(pg_temp.v('ws'), null, '  ', null, null,
  null, pg_temp.v('tower'), null, null)$$, 'name_required', 'a worker needs a name');
select pg_temp.check(pg_temp.on_board(pg_temp.board(), 'Ali')
  and (select x ->> 'user_id' is null and x ->> 'job_title' = 'Mason' and x ->> 'site_name' = 'HQ'
       from jsonb_array_elements(pg_temp.board() -> 'people') x where x ->> 'name' = 'Ali'),
  'the worker is on the lead''s board, with their details');
select pg_temp.check(pg_temp.on_board(pg_temp.board(pg_temp.v('tower')), 'Ali')
  and pg_temp.on_board(pg_temp.board(pg_temp.v('tower')), 'Sami'),
  'filtering by project keeps its members and workers');
select pg_temp.login(946);
select pg_temp.check(not pg_temp.on_board(pg_temp.board(), 'Ali'), 'other leads do not see the worker');
select pg_temp.fails($$select public.save_attendance_worker(pg_temp.v('ws'), pg_temp.v('ali'), 'Ali',
  null, null, null, pg_temp.v('mall'), null, null)$$, 'not_allowed',
  'nor change them');

-- The free plan gives two free workers when set so; then none unless the
-- plan has a price per extra worker.
reset role;
update public.plans set free_workers = 2 where id = 'free';
select pg_temp.login(941);
insert into ctx values ('kamal', public.save_attendance_worker(pg_temp.v('ws'), null, 'Kamal', null, null,
  null, null, null, null));
select pg_temp.check((pg_temp.board() -> 'workers' ->> 'used')::int = 2
  and (pg_temp.board() -> 'workers' ->> 'free')::int = 2, 'two of two free workers used');
select pg_temp.fails($$select public.save_attendance_worker(pg_temp.v('ws'), null, 'Third', null, null,
  null, null, null, null)$$, 'workers_limit', 'no more workers past the free number');
reset role;
update public.plans set extra_worker_usd = 1.5 where id = 'free';
select pg_temp.login(941);
insert into ctx values ('third', public.save_attendance_worker(pg_temp.v('ws'), null, 'Third', null, null,
  null, null, null, null));
select pg_temp.check((pg_temp.board() -> 'workers' ->> 'used')::int = 3,
  'extra workers can be added when the plan prices them');
select public.remove_attendance_worker(pg_temp.v('third'));
select pg_temp.check(not pg_temp.on_board(pg_temp.board(), 'Third')
  and (pg_temp.board() -> 'workers' ->> 'used')::int = 2, 'a removed worker leaves the board');
reset role;
update public.plans set free_workers = null, extra_worker_usd = 0 where id = 'free';

-- 3. Roll call.
select pg_temp.login(942);
select pg_temp.check((public.attendance_roll_call(pg_temp.v('ws'), 'in',
    pg_temp.entry(pg_temp.v('ali'), pg_temp.t('start'))
    || pg_temp.entry(pg_temp.person(943), now()),
    24.7140, 46.6753, 12) ->> 'recorded')::int = 2,
  'a lead checks in two people at once');
reset role;
select pg_temp.check(
  (select late_minutes = 0 and in_by = pg_temp.uid(942) and in_site_id = pg_temp.v('hq')
          and in_lat = 24.7140 and not outside and review = 'none'
   from public.attendance_records where person_id = pg_temp.v('ali')),
  'on time, recorded by the lead, at the lead''s place');
select pg_temp.check(
  (select late_minutes between 115 and 125 from public.attendance_records
   where person_id = pg_temp.person(943)),
  'checked in now is two hours late');
select pg_temp.login(942);
select pg_temp.check(
  (public.attendance_roll_call(pg_temp.v('ws'), 'in', pg_temp.entry(pg_temp.v('ali'), now())) -> 'skipped')
    = jsonb_build_array(pg_temp.v('ali')),
  'someone already in is skipped');
select pg_temp.fails($$select public.attendance_roll_call(pg_temp.v('ws'), 'in',
  pg_temp.entry(pg_temp.person(943), now() + interval '1 hour'))$$, 'future_time', 'no future times');
select pg_temp.fails($$select public.attendance_roll_call(pg_temp.v('ws'), 'in',
  pg_temp.entry(pg_temp.person(944), now()))$$, 'not_allowed', 'only people the lead manages');
select pg_temp.fails($$select public.attendance_roll_call(pg_temp.v('ws'), 'in',
  pg_temp.entry(pg_temp.person(942), now()))$$, 'not_allowed', 'a lead cannot check themselves in');
select pg_temp.fails($$select public.attendance_roll_call(pg_temp.v('ws'), 'sideways',
  pg_temp.entry(pg_temp.v('ali'), now()))$$, 'invalid_kind', 'in or out only');
select pg_temp.check((public.attendance_roll_call(pg_temp.v('ws'), 'out',
    pg_temp.entry(pg_temp.v('ali'), now())) ->> 'recorded')::int = 1, 'the lead checks the worker out');
select pg_temp.login(941);
select pg_temp.check((public.attendance_roll_call(pg_temp.v('ws'), 'out',
    pg_temp.entry(pg_temp.v('kamal'), now())) -> 'skipped') = jsonb_build_array(pg_temp.v('kamal')),
  'checking out skips someone who is not in');
reset role;
select pg_temp.check(
  (select out_at is not null and out_by = pg_temp.uid(942) from public.attendance_records
   where person_id = pg_temp.v('ali')), 'the worker is checked out');
select pg_temp.login(941);
select pg_temp.check((public.attendance_roll_call(pg_temp.v('ws'), 'in',
    pg_temp.entry(pg_temp.person(941), now())) ->> 'recorded')::int = 1,
  'owners may record themselves');
select pg_temp.check(
  (select x -> 'record' ->> 'in_by_name' from jsonb_array_elements(pg_temp.board() -> 'people') x
   where x ->> 'name' = 'Ali') = 'Laila',
  'the board says who recorded it');

-- 4. Changing times, with a log.
select pg_temp.login(942);
reset role;
insert into ctx select 'rs', id::text from public.attendance_records where person_id = pg_temp.person(943);
select pg_temp.login(942);
select public.set_attendance_times(pg_temp.v('rs'),
  pg_temp.t('start') + interval '10 minutes', null, 'Was at the gate');
reset role;
select pg_temp.check(
  (select late_minutes = 0 from public.attendance_records where id = pg_temp.v('rs'))
  and (select count(*) = 1 and bool_and(field = 'in' and edited_by = pg_temp.uid(942)
                                        and detail = 'Was at the gate')
       from public.attendance_edits where record_id = pg_temp.v('rs')),
  'within the grace minutes is on time, and the change is logged');
select pg_temp.login(942);
select pg_temp.fails($$select public.set_attendance_times(pg_temp.v('rs'), now() - interval '1 hour',
  now() + interval '2 hours')$$, 'future_time', 'no check-out in the future');
select pg_temp.fails($$select public.set_attendance_times(pg_temp.v('rs'), now() - interval '1 hour',
  now() - interval '2 hours')$$, 'invalid_hours', 'out after in');
select pg_temp.check(
  (public.attendance_person_day(pg_temp.person(943),
         (public.attendance_today(pg_temp.v('ws')) ->> 'today')::date) ->> 'can_edit')::boolean
  and jsonb_array_length(public.attendance_person_day(pg_temp.person(943),
         (public.attendance_today(pg_temp.v('ws')) ->> 'today')::date) -> 'edits') = 1,
  'the person''s day shows the change');
select pg_temp.login(943);
select pg_temp.check(
  not (public.attendance_person_day(pg_temp.person(943),
         (public.attendance_today(pg_temp.v('ws')) ->> 'today')::date) ->> 'can_edit')::boolean,
  'people see their own day but cannot change it');
select pg_temp.fails($$select public.set_attendance_times(pg_temp.v('rs'), now(), null)$$,
  'not_allowed', 'nor change their own times');
select pg_temp.login(946);
select pg_temp.fails($$select public.attendance_person_day(pg_temp.person(943), current_date)$$,
  'not_allowed', 'other leads cannot see the day');

-- 5. Reviewing a check-in from outside: Hoda is in no project, so the
-- owner reviews it.
select pg_temp.login(944);
insert into ctx values ('rh', (public.attendance_check_in(pg_temp.v('ws'), 24.80, 46.70, 20, null,
  'client', 'At a client')) ->> 'id');
select pg_temp.login(942);
select pg_temp.fails($$select public.review_attendance(pg_temp.v('rh'), true)$$, 'not_allowed',
  'a lead cannot review someone outside their projects');
select pg_temp.login(941);
select pg_temp.check(jsonb_array_length(public.attendance_requests(pg_temp.v('ws')) -> 'reviews') = 1
  and (public.attendance_requests(pg_temp.v('ws')) -> 'reviews' -> 0 ->> 'name') = 'Hoda'
  and (pg_temp.board() ->> 'requests')::int = 1, 'the owner has one check-in to review');
select public.review_attendance(pg_temp.v('rh'), true);
select pg_temp.fails($$select public.review_attendance(pg_temp.v('rh'), false)$$, 'already_reviewed',
  'a check-in is reviewed once');
reset role;
select pg_temp.check(
  (select review = 'accepted' and reviewed_by = pg_temp.uid(941) from public.attendance_records
   where id = pg_temp.v('rh'))
  and exists (select 1 from public.attendance_edits where record_id = pg_temp.v('rh') and field = 'review'),
  'accepted, by the owner, and logged');
-- Omar made the projects, so he leads them too.
select pg_temp.check(pg_temp.uid(942) = any (public.attendance_managers_of(pg_temp.person(943)))
  and not pg_temp.uid(943) = any (public.attendance_managers_of(pg_temp.person(943)))
  and public.attendance_managers_of(pg_temp.person(944)) = array[pg_temp.uid(941)]
  and public.attendance_managers_of(pg_temp.person(942)) = array[pg_temp.uid(941)],
  'leads hear about their people; owners and admins about the rest');

-- 6. Corrections.
select pg_temp.login(944);
insert into ctx values ('today', public.attendance_today(pg_temp.v('ws')) ->> 'today');
insert into ctx values ('f1', public.request_attendance_fix(pg_temp.v('ws'),
  (select v::date from ctx where k = 'today') - 1,
  pg_temp.t('start') - interval '1 day' + interval '30 minutes',
  pg_temp.t('start') - interval '1 day' + interval '8 hours',
  'Forgot my phone'));
select pg_temp.fails($$select public.request_attendance_fix(pg_temp.v('ws'),
  (select v::date from ctx where k = 'today') - 1, now() - interval '1 day', null, 'Again')$$,
  'fix_pending', 'one open correction per day');
select pg_temp.fails($$select public.request_attendance_fix(pg_temp.v('ws'),
  (select v::date from ctx where k = 'today') + 1, now(), null, 'Tomorrow')$$,
  'invalid_day', 'not for days to come');
select pg_temp.fails($$select public.request_attendance_fix(pg_temp.v('ws'),
  (select v::date from ctx where k = 'today') - 2, now() - interval '2 days', null, '  ')$$,
  'fix_note_required', 'a correction says why');
select pg_temp.fails($$select public.decide_attendance_fix(pg_temp.v('f1'), true)$$, 'not_allowed',
  'nobody decides their own correction');
select pg_temp.login(942);
select pg_temp.check(jsonb_array_length(public.attendance_requests(pg_temp.v('ws')) -> 'fixes') = 0,
  'a lead does not see corrections of people outside their projects');
select pg_temp.login(941);
select pg_temp.check(jsonb_array_length(public.attendance_requests(pg_temp.v('ws')) -> 'fixes') = 1,
  'the owner sees the correction');
select public.decide_attendance_fix(pg_temp.v('f1'), true, 'OK');
reset role;
select pg_temp.check(
  (select late_minutes = 30 and out_at is not null and in_by = pg_temp.uid(941)
   from public.attendance_records
   where person_id = pg_temp.person(944) and day = (select v::date from ctx where k = 'today') - 1),
  'accepting makes the missing day, late by 30 minutes');
select pg_temp.login(944);
select pg_temp.check(
  (public.my_attendance_fixes(pg_temp.v('ws'), current_date - 40, current_date + 1) -> 0 ->> 'status')
    = 'accepted', 'the person sees it was accepted');

-- A correction of today's check-out only.
insert into ctx values ('f2', public.request_attendance_fix(pg_temp.v('ws'),
  (select v::date from ctx where k = 'today'), null, now(), 'Left early'));
select public.cancel_attendance_fix(pg_temp.v('f2'));
insert into ctx values ('f3', public.request_attendance_fix(pg_temp.v('ws'),
  (select v::date from ctx where k = 'today'), null, now(), 'Left early'));
select pg_temp.login(941);
select public.decide_attendance_fix(pg_temp.v('f3'), true);
reset role;
select pg_temp.check(
  (select out_at is not null and out_by = pg_temp.uid(941) from public.attendance_records
   where id = pg_temp.v('rh'))
  and exists (select 1 from public.attendance_edits where record_id = pg_temp.v('rh') and field = 'out'),
  'accepting a check-out sets it and logs it');

-- 7. Deleting a mistake keeps a trace.
select pg_temp.login(942);
reset role;
insert into ctx select 'ra', id::text from public.attendance_records where person_id = pg_temp.v('ali');
select pg_temp.login(942);
select public.delete_attendance_record(pg_temp.v('ra'), 'Wrong person');
reset role;
select pg_temp.check(
  not exists (select 1 from public.attendance_records where id = pg_temp.v('ra'))
  and exists (select 1 from public.attendance_edits where person_id = pg_temp.v('ali')
              and field = 'deleted' and detail = 'Wrong person'),
  'a deleted record is logged');

-- 8. Branch and shift for someone with the app.
select pg_temp.login(942);
select public.assign_attendance(pg_temp.person(943), pg_temp.v('hq'), pg_temp.v('shift'));
reset role;
select pg_temp.check((select site_id = pg_temp.v('hq') from public.attendance_people
                      where id = pg_temp.person(943)), 'a lead sets a person''s branch');

-- 9. Reminders: Nour and Laila have not checked in, two hours into the shift.
reset role;
select public.process_attendance_reminders();
select public.process_attendance_reminders();
select pg_temp.check(
  (select count(*) from public.attendance_reminders_sent where person_id = pg_temp.person(946)) = 1
  and (select count(*) from public.attendance_reminders_sent where person_id = pg_temp.person(942)) = 1
  and not exists (select 1 from public.attendance_reminders_sent where person_id = pg_temp.person(943)),
  'one reminder for each person not in yet');
select pg_temp.login(941);
select pg_temp.fails($$select public.process_attendance_reminders()$$, '42501',
  'reminders run on the server only');

-- 10. Extra workers on the invoice: 2 workers, 1 free on Basic, 2 USD each.
reset role;
insert into public.platform_admins (user_id) values (pg_temp.uid(941));
update public.plans set price_usd_month = 10, free_workers = 1, extra_worker_usd = 2 where id = 'basic';
select pg_temp.login(941);
insert into ctx values ('inv', public.admin_create_invoice(
  (select company_id from public.workspaces where id = pg_temp.v('ws')),
  jsonb_build_array(jsonb_build_object('workspace_id', pg_temp.v('ws'), 'plan_id', 'basic')), 2));
reset role;
select pg_temp.check(
  (select extra_workers = 1 and extra_worker_usd = 2 and amount_usd = 24
   from public.invoice_lines where invoice_id = pg_temp.v('inv'))
  and (select total_usd = 24 from public.invoices where id = pg_temp.v('inv')),
  'the invoice adds the worker past the free number');
select pg_temp.login(941);
select pg_temp.check(
  (select free_workers = 1 and extra_worker_usd = 2 from public.admin_plans() where id = 'basic'),
  'admin plans list the worker limits');
select public.admin_set_plan_workers('basic', null, 0);
select pg_temp.check(
  (select free_workers is null and extra_worker_usd = 0 from public.admin_plans() where id = 'basic'),
  'platform admins set the worker limits');
select pg_temp.login(942);
select pg_temp.fails($$select public.admin_set_plan_workers('basic', 5, 1)$$, 'not_allowed',
  'only platform admins set them');
reset role;
delete from public.platform_admins where user_id = pg_temp.uid(941);
update public.plans set price_usd_month = 0 where id = 'basic';
