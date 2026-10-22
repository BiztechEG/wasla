-- Invitations and join requests as notifications: who hears of them, where
-- they stand, and that answering one clears it for everybody.
-- Uses its own users so it does not depend on other test files.

\set ON_ERROR_STOP on

-- Users: Rana (owner), Karim (admin), Laila (member), Omar (invited),
-- Sara (asks to join). Badr signs up later.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000061', 'rana@inbox.example.com',  '{"full_name":"Rana"}'),
  ('00000000-0000-0000-0000-000000000062', 'karim@inbox.example.com', '{"full_name":"Karim"}'),
  ('00000000-0000-0000-0000-000000000063', 'laila@inbox.example.com', '{"full_name":"Laila"}'),
  ('00000000-0000-0000-0000-000000000064', 'omar@inbox.example.com',  '{"full_name":"Omar"}'),
  ('00000000-0000-0000-0000-000000000065', 'sara@inbox.example.com',  '{"full_name":"Sara"}');

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

create function pg_temp.ws() returns uuid language sql as $$ select v::uuid from ctx where k = 'ws' $$;

-- 1. Rana opens a discoverable workspace with Karim as admin and Laila as member.
select pg_temp.login(61);
insert into ctx values ('ws', public.create_company_workspace('Saqqara', 'eg', 'Saqqara Desk'));
update public.workspaces set discoverable = true where id = pg_temp.ws();
insert into public.invites (workspace_id, email, role, invited_by) values
  (pg_temp.ws(), 'karim@inbox.example.com', 'admin', auth.uid()),
  (pg_temp.ws(), 'laila@inbox.example.com', 'member', auth.uid());

select pg_temp.login(62);
select pg_temp.check(
  (select kind = 'invite' and workspace_name = 'Saqqara Desk' and actor_name = 'Rana'
          and detail = 'admin' and request_status = 'pending' and read_at is null
   from public.my_notifications()),
  'an invited person with an account is told at once');
select public.accept_invite((select token from public.my_invites()));
select pg_temp.check(
  (select read_at is not null and request_status = 'accepted' from public.my_notifications()
   where kind = 'invite'),
  'accepting clears the invitation and shows it accepted');

select pg_temp.login(63);
select public.accept_invite((select token from public.my_invites()));

select pg_temp.login(61);
select pg_temp.check(
  (select count(*) from public.my_notifications() where kind = 'invite_accepted') = 2,
  'the admin who invited hears of each acceptance');
select pg_temp.check(
  (select actor_name from public.my_notifications()
   where kind = 'invite_accepted' order by created_at limit 1) = 'Karim',
  'and who accepted');

-- 2. Inviting someone already in tells nobody.
insert into public.invites (workspace_id, email, role, invited_by)
values (pg_temp.ws(), 'laila@inbox.example.com', 'admin', auth.uid());
select pg_temp.login(63);
select pg_temp.check(
  (select count(*) from public.my_notifications() where kind = 'invite') = 1,
  'a member invited again gets no new invitation notice');

-- 3. Omar declines; a cancelled invitation reads as no longer open.
select pg_temp.login(61);
insert into public.invites (workspace_id, email, role, invited_by)
values (pg_temp.ws(), 'omar@inbox.example.com', 'member', auth.uid());
select pg_temp.login(64);
select public.decline_invite((select token from public.my_invites()));
select pg_temp.check(
  (select read_at is not null and request_status = 'rejected' from public.my_notifications()),
  'declining clears the invitation');

select pg_temp.login(61);
insert into public.invites (workspace_id, email, role, invited_by)
values (pg_temp.ws(), 'omar@inbox.example.com', 'member', auth.uid())
returning id::text as omar_invite \gset
update public.invites set status = 'cancelled' where id = :'omar_invite';
select pg_temp.login(64);
select pg_temp.check(
  (select read_at is not null and request_status = 'cancelled' from public.my_notifications()
   where invite_id = :'omar_invite'),
  'a cancelled invitation is cleared and shown cancelled');

-- 4. An expired invitation says so.
reset role;
insert into public.invites (workspace_id, email, role, invited_by)
values (pg_temp.ws(), 'omar@inbox.example.com', 'member', '00000000-0000-0000-0000-000000000061')
returning id::text as old_invite \gset
update public.invites set expires_at = now() - interval '1 minute' where id = :'old_invite';
select pg_temp.login(64);
select pg_temp.check(
  (select request_status from public.my_notifications() where invite_id = :'old_invite') = 'expired',
  'an expired invitation shows as expired');

-- 5. Badr, invited before he has an account, finds it when he signs up.
select pg_temp.login(61);
insert into public.invites (workspace_id, email, role, invited_by)
values (pg_temp.ws(), 'Badr@Inbox.Example.com', 'member', auth.uid());
reset role;
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000066', 'badr@inbox.example.com', '{"full_name":"Badr"}');
select pg_temp.login(66);
select pg_temp.check(
  (select count(*) from public.my_notifications()
   where kind = 'invite' and request_status = 'pending') = 1,
  'someone who signs up after being invited finds the invitation');

-- 6. Sara asks to join: owners and admins hear of it, members do not.
select pg_temp.login(65);
insert into ctx values ('req', public.request_to_join(pg_temp.ws(), 'From the Cairo office'));

select pg_temp.login(61);
select pg_temp.check(
  (select actor_name = 'Sara' and detail = 'From the Cairo office' and request_status = 'pending'
   from public.my_notifications() where kind = 'join_request'),
  'the owner hears of a request to join, with its message');
select pg_temp.login(62);
select pg_temp.check(
  exists (select 1 from public.my_notifications() where kind = 'join_request'),
  'an admin hears of it too');
select pg_temp.login(63);
select pg_temp.check(
  not exists (select 1 from public.my_notifications() where kind = 'join_request'),
  'a member does not');

-- 7. Karim accepts: Sara hears, and the request is cleared for Rana too.
select pg_temp.login(62);
select public.decide_join_request((select v::uuid from ctx where k = 'req'), true);
select pg_temp.login(61);
select pg_temp.check(
  (select read_at is not null and request_status = 'accepted'
   from public.my_notifications() where kind = 'join_request'),
  'one admin answering clears the request for the others');
select pg_temp.login(65);
select pg_temp.check(
  (select actor_name = 'Karim' and workspace_name = 'Saqqara Desk' and read_at is null
   from public.my_notifications() where kind = 'request_accepted'),
  'the person asking hears they were accepted, and by whom');

-- 8. A withdrawn request is cleared; a declined one is told.
select pg_temp.login(64);
insert into ctx values ('req2', public.request_to_join(pg_temp.ws()));
select public.cancel_join_request((select v::uuid from ctx where k = 'req2'));
select pg_temp.login(61);
select pg_temp.check(
  (select read_at is not null and request_status = 'cancelled' from public.my_notifications()
   where join_request_id = (select v::uuid from ctx where k = 'req2')),
  'a withdrawn request is cleared');

select pg_temp.login(64);
insert into ctx values ('req3', public.request_to_join(pg_temp.ws()));
select pg_temp.login(61);
select public.decide_join_request((select v::uuid from ctx where k = 'req3'), false);
select pg_temp.login(64);
select pg_temp.check(
  exists (select 1 from public.my_notifications() where kind = 'request_declined'),
  'the person asking hears they were declined');

-- 9. Phones are told where to open.
reset role;
insert into public.push_tokens (token, user_id, platform)
values (repeat('t', 30), '00000000-0000-0000-0000-000000000061', 'android');
select pg_temp.login(64);
insert into ctx values ('req4', public.request_to_join(pg_temp.ws()));
reset role;
select pg_temp.check(
  (select data ->> 'type' from public.push_outbox
   where user_id = '00000000-0000-0000-0000-000000000061' and kind = 'join_request'
   order by id desc limit 1) = 'join_requests',
  'a request to join opens the requests on the phone');

-- 10. Nobody reads anyone else's.
select pg_temp.login(63);
select pg_temp.check(
  not exists (select 1 from public.notifications where kind in ('join_request', 'request_accepted')),
  'notifications stay with their person');

reset role;
