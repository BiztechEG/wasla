-- Attendance: setting it up, checking in and out, lateness, branches,
-- selfies, and who sees whose records.

\set ON_ERROR_STOP on

-- Users: Omar (owner), Laila (project lead), Sami (in Laila's project),
-- Hoda (member, in no project), Tarek (outsider).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000931', 'omar@example.com',  '{"full_name":"Omar"}'),
  ('00000000-0000-0000-0000-000000000932', 'laila@example.com', '{"full_name":"Laila"}'),
  ('00000000-0000-0000-0000-000000000933', 'sami@example.com',  '{"full_name":"Sami"}'),
  ('00000000-0000-0000-0000-000000000934', 'hoda@example.com',  '{"full_name":"Hoda"}'),
  ('00000000-0000-0000-0000-000000000935', 'tarek@example.com', '{"full_name":"Tarek"}');

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

select pg_temp.login(931);
insert into ctx values ('ws', public.create_company_workspace('Najd', 'sa', 'Najd Build'));
insert into public.invites (workspace_id, email, role, invited_by) values
  (pg_temp.v('ws'), 'laila@example.com', 'member', auth.uid()),
  (pg_temp.v('ws'), 'sami@example.com',  'member', auth.uid()),
  (pg_temp.v('ws'), 'hoda@example.com',  'member', auth.uid());
do $$
begin
  for n in 932..934 loop
    perform pg_temp.login(n);
    perform public.accept_invite((select token from public.my_invites() limit 1));
  end loop;
end $$;

select pg_temp.login(931);
with p as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.v('ws'), 'Tower', auth.uid()) returning id
)
insert into ctx select 'p', id::text from p;
insert into public.project_members (project_id, user_id, role) values
  (pg_temp.v('p'), pg_temp.uid(932), 'lead'),
  (pg_temp.v('p'), pg_temp.uid(933), 'member');

-- 1. Off until an admin turns it on.
select pg_temp.login(933);
select pg_temp.check(public.attendance_today(pg_temp.v('ws')) ->> 'enabled' = 'false',
  'attendance is off at first');
select pg_temp.fails($$select public.attendance_check_in(pg_temp.v('ws'), 24.7, 46.6)$$,
  'attendance_off', 'no checking in while off');
select pg_temp.fails($$select public.enable_attendance(pg_temp.v('ws'), 'Morning')$$,
  'not_allowed', 'members cannot turn it on');
select pg_temp.fails($$select public.attendance_setup(pg_temp.v('ws'))$$,
  'not_allowed', 'members cannot see the setup');
select pg_temp.login(935);
select pg_temp.fails($$select public.attendance_today(pg_temp.v('ws'))$$,
  'not_allowed', 'outsiders see nothing');

select pg_temp.login(931);
select public.enable_attendance(pg_temp.v('ws'), 'Morning');
select pg_temp.check(
  (public.attendance_setup(pg_temp.v('ws')) ->> 'timezone') = 'Asia/Riyadh',
  'the time zone follows the company''s country');
select pg_temp.check(
  jsonb_array_length(public.attendance_setup(pg_temp.v('ws')) -> 'shifts') = 1
  and (public.attendance_setup(pg_temp.v('ws')) -> 'shifts' -> 0 ->> 'name') = 'Morning'
  and (public.attendance_setup(pg_temp.v('ws')) ->> 'default_shift_id')
      = (public.attendance_setup(pg_temp.v('ws')) -> 'shifts' -> 0 ->> 'id'),
  'turning it on makes a first shift, the default');
select public.enable_attendance(pg_temp.v('ws'), 'Again');
select pg_temp.check(
  jsonb_array_length(public.attendance_setup(pg_temp.v('ws')) -> 'shifts') = 1,
  'turning it on again adds nothing');

-- A shift that started two hours ago (local time), so checking in is late,
-- and no days off so today counts.
insert into ctx values ('shift', public.attendance_setup(pg_temp.v('ws')) ->> 'default_shift_id');
select public.save_attendance_shift(pg_temp.v('ws'), pg_temp.v('shift'), 'Morning',
  ((now() at time zone 'Asia/Riyadh') - interval '2 hours')::time,
  ((now() at time zone 'Asia/Riyadh') + interval '6 hours')::time, 15);
select public.save_attendance_settings(pg_temp.v('ws'), true, '{}', false, true, true,
  pg_temp.v('shift'), null, null, null, null);
select pg_temp.fails($$select public.save_attendance_shift(pg_temp.v('ws'), null, 'Bad', '09:00', '09:00', 0)$$,
  'invalid_hours', 'a shift needs different start and end');
select pg_temp.fails($$select public.save_attendance_settings(pg_temp.v('ws'), true, '{}', false, true, true,
  gen_random_uuid(), null, null, null, null)$$,
  'not_found', 'the default shift must be one of the workspace''s');

-- Branches: HQ in Riyadh (150 m) and a field branch.
insert into ctx values ('hq', public.save_attendance_site(pg_temp.v('ws'), null, 'HQ', 24.7136, 46.6753, 150));
insert into ctx values ('field', public.save_attendance_site(pg_temp.v('ws'), null, 'Field', null, null, null));
select pg_temp.check(
  jsonb_array_length(public.attendance_setup(pg_temp.v('ws')) -> 'sites') = 2,
  'two branches');
select pg_temp.login(933);
select pg_temp.fails($$select public.save_attendance_site(pg_temp.v('ws'), null, 'Mine', 1, 1, 100)$$,
  'not_allowed', 'members cannot add branches');

-- 2. Checking in near HQ (about 55 m away), late by about two hours.
select pg_temp.check(public.attendance_today(pg_temp.v('ws')) ->> 'enabled' = 'true'
  and public.attendance_today(pg_temp.v('ws')) -> 'record' = 'null'::jsonb
  and public.attendance_today(pg_temp.v('ws')) -> 'shift' ->> 'name' = 'Morning',
  'the screen shows the shift and no record yet');
select pg_temp.fails($$select public.attendance_check_in(pg_temp.v('ws'), null, null)$$,
  'location_required', 'checking in needs a location');
insert into ctx values ('r1', (public.attendance_check_in(pg_temp.v('ws'), 24.7141, 46.6753, 10)) ->> 'id');
reset role;
select pg_temp.check(
  (select not outside and review = 'none' and in_distance_m between 40 and 70
          and in_site_id = pg_temp.v('hq') and late_minutes between 115 and 125
          and in_by = pg_temp.uid(933)
   from public.attendance_records where id = pg_temp.v('r1')),
  'checked in at HQ, inside, late by two hours');
select pg_temp.login(933);
select pg_temp.check(
  public.attendance_today(pg_temp.v('ws')) -> 'record' ->> 'id' = pg_temp.v('r1')::text
  and (public.attendance_today(pg_temp.v('ws')) -> 'record' ->> 'in_site') = 'HQ'
  and (public.attendance_today(pg_temp.v('ws')) -> 'month' ->> 'late')::int = 1,
  'the screen shows today''s record and this month''s lateness');
select pg_temp.fails($$select public.attendance_check_in(pg_temp.v('ws'), 24.7141, 46.6753)$$,
  'already_checked_in', 'only one check-in a day');

-- 3. Far away: needs a reason, then waits for review.
select pg_temp.login(934);
select pg_temp.fails($$select public.attendance_check_in(pg_temp.v('ws'), 24.80, 46.70, 20)$$,
  'reason_required', 'checking in from outside needs a reason');
select pg_temp.fails($$select public.attendance_check_in(pg_temp.v('ws'), 24.80, 46.70, 20, null, 'party')$$,
  'reason_required', 'the reason must be a known kind');
insert into ctx values ('r2', (public.attendance_check_in(pg_temp.v('ws'), 24.80, 46.70, 20, null,
  'client', '  At Al Noor  ')) ->> 'id');
reset role;
select pg_temp.check(
  (select outside and review = 'pending' and reason_kind = 'client' and reason_note = 'At Al Noor'
          and in_distance_m > 5000
   from public.attendance_records where id = pg_temp.v('r2')),
  'outside check-in kept with its reason, waiting for review');

-- Outside not allowed at all.
select pg_temp.login(931);
select public.save_attendance_settings(pg_temp.v('ws'), true, '{}', false, false, true,
  pg_temp.v('shift'), null, null, null, null);
select pg_temp.fails($$select public.attendance_check_in(pg_temp.v('ws'), 24.80, 46.70, 20, null, 'client')$$,
  'outside_not_allowed', 'outside check-ins can be turned off');

-- A person tied to the field branch is fine anywhere.
reset role;
insert into public.attendance_people (workspace_id, user_id, site_id)
values (pg_temp.v('ws'), pg_temp.uid(931), pg_temp.v('field'));
select pg_temp.login(931);
select pg_temp.check(
  (public.attendance_check_in(pg_temp.v('ws'), 30.0, 31.2) ->> 'outside')::boolean = false,
  'a field person checks in anywhere');

-- 4. Selfies.
select public.save_attendance_settings(pg_temp.v('ws'), true, '{}', true, true, true,
  pg_temp.v('shift'), null, null, null, null);
select pg_temp.login(932);
select pg_temp.fails($$select public.attendance_check_in(pg_temp.v('ws'), 24.7136, 46.6753)$$,
  'selfie_required', 'a selfie is needed when the company asks');
insert into ctx values ('selfie', pg_temp.v('ws') || '/' || pg_temp.uid(932) || '/selfie.jpg');
select pg_temp.fails($$select public.attendance_check_in(pg_temp.v('ws'), 24.7136, 46.6753, 5,
  (select v from ctx where k = 'selfie'))$$,
  'invalid_file', 'the selfie must be uploaded first');
reset role;
insert into storage.objects (bucket_id, name, metadata)
values ('files', (select v from ctx where k = 'selfie'), '{"size": 1000}');
select pg_temp.login(932);
select pg_temp.fails($$select public.attendance_check_in(pg_temp.v('ws'), 24.7136, 46.6753, 5,
  pg_temp.v('ws') || '/' || pg_temp.uid(933) || '/x.jpg')$$,
  'invalid_file', 'not someone else''s upload');
insert into ctx values ('r3', (public.attendance_check_in(pg_temp.v('ws'), 24.7136, 46.6753, 5,
  (select v from ctx where k = 'selfie'))) ->> 'id');
reset role;
select pg_temp.check(
  (select in_photo_path from public.attendance_records where id = pg_temp.v('r3'))
    = (select v from ctx where k = 'selfie'),
  'checked in with a selfie');
insert into ctx select 'p1', person_id::text from public.attendance_records where id = pg_temp.v('r1');
insert into ctx select 'p2', person_id::text from public.attendance_records where id = pg_temp.v('r2');
select pg_temp.login(932);
select pg_temp.check(not public.can_remove_object((select v from ctx where k = 'selfie')),
  'a selfie cannot be removed afterwards');
select pg_temp.login(931);
select pg_temp.check(public.can_read_object((select v from ctx where k = 'selfie')),
  'the owner sees the selfie');
select pg_temp.login(934);
select pg_temp.check(not public.can_read_object((select v from ctx where k = 'selfie')),
  'other members do not');

-- 5. Who sees whose attendance.
select pg_temp.login(932);
select pg_temp.check(public.can_see_attendance(
  pg_temp.v('p1')),
  'a lead sees people in their project');
select pg_temp.check(not public.can_see_attendance(
  pg_temp.v('p2')),
  'a lead does not see people outside their projects');
select pg_temp.login(934);
select pg_temp.check(not public.can_see_attendance(
  pg_temp.v('p1')),
  'members do not see each other');
select pg_temp.check(public.can_see_attendance(
  pg_temp.v('p2')),
  'people see their own');
select pg_temp.fails($$select count(*) from public.attendance_records$$,
  '42501', 'records are only read through functions');
select pg_temp.login(931);
select pg_temp.check(public.can_manage_attendance(
  pg_temp.v('p2')),
  'the owner sees everyone');

-- 6. Checking out.
select pg_temp.login(933);
select pg_temp.check(
  (public.attendance_check_out(pg_temp.v('ws'), 24.7136, 46.6753, 5) ->> 'out_at') is not null,
  'checked out');
select pg_temp.fails($$select public.attendance_check_out(pg_temp.v('ws'), 24.7136, 46.6753)$$,
  'not_checked_in', 'nothing left to check out of');
select pg_temp.check(jsonb_array_length(public.my_attendance(pg_temp.v('ws'),
  current_date - 30, current_date + 1)) = 1, 'one day in the history');
select pg_temp.login(935);
select pg_temp.check(jsonb_array_length(public.my_attendance(pg_temp.v('ws'),
  current_date - 30, current_date + 1)) = 0, 'outsiders have no history');

-- 7. Ramadan hours replace the shift's.
select pg_temp.login(931);
select public.save_attendance_settings(pg_temp.v('ws'), true, '{5,6}', false, true, true,
  pg_temp.v('shift'), date '2027-02-08', date '2027-03-09', '10:00', '15:00');
reset role;
select pg_temp.check(
  (select start_at = timestamptz '2027-02-10 10:00+03' and end_at = timestamptz '2027-02-10 15:00+03'
   from public.attendance_hours(pg_temp.v('ws'), pg_temp.v('shift'), date '2027-02-10')),
  'Ramadan hours apply in Ramadan');
select pg_temp.login(931);
select public.save_attendance_shift(pg_temp.v('ws'), pg_temp.v('shift'), 'Night', '22:00', '06:00', 10);
reset role;
select pg_temp.check(
  (select end_at = timestamptz '2027-04-02 06:00+03'
   from public.attendance_hours(pg_temp.v('ws'), pg_temp.v('shift'), date '2027-04-01')),
  'a night shift ends the next morning');

-- 8. Deleting a shift and a branch keeps the records.
select pg_temp.login(931);
select public.delete_attendance_site(pg_temp.v('ws'), pg_temp.v('hq'));
select public.delete_attendance_shift(pg_temp.v('ws'), pg_temp.v('shift'));
select pg_temp.check(
  (public.attendance_setup(pg_temp.v('ws')) ->> 'default_shift_id') is null
  and jsonb_array_length(public.attendance_setup(pg_temp.v('ws')) -> 'sites') = 1,
  'shift and branch deleted');
reset role;
select pg_temp.check(
  (select count(*) from public.attendance_records where workspace_id = pg_temp.v('ws')) = 4,
  'records stay');

\echo 'all attendance tests passed'
