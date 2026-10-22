-- Muted chats and quiet hours: what still reaches the phone.
-- Uses its own users so it does not depend on other test files.

\set ON_ERROR_STOP on

-- Users: Huda (owner), Sherif (in the project), Lina (not in it).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000051', 'huda@quiet.example.com',   '{"full_name":"Huda"}'),
  ('00000000-0000-0000-0000-000000000052', 'sherif@quiet.example.com', '{"full_name":"Sherif"}'),
  ('00000000-0000-0000-0000-000000000053', 'lina@quiet.example.com',   '{"full_name":"Lina"}');

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
  select ('00000000-0000-0000-0000-0000000000' || n)::uuid $$;
-- What is queued for Sherif's phone, read as the server.
create function pg_temp.queued(what text) returns bigint language sql security definer as $$
  select count(*) from public.push_outbox
  where user_id = '00000000-0000-0000-0000-000000000052' and kind = what $$;
create function pg_temp.clear() returns void language sql security definer as $$
  delete from public.push_outbox where user_id = '00000000-0000-0000-0000-000000000052' $$;

-- Huda's workspace, with Sherif in the project; Sherif has a phone.
select pg_temp.login(51);
insert into ctx values ('ws', public.create_company_workspace('Quiet Co', 'eg', 'Quiet Desk'));
insert into public.invites (workspace_id, email, role, invited_by) values
  (pg_temp.v('ws'), 'sherif@quiet.example.com', 'member', auth.uid()),
  (pg_temp.v('ws'), 'lina@quiet.example.com', 'member', auth.uid());
select pg_temp.login(52);
select public.accept_invite((select token from public.my_invites()));
select public.register_push_token(repeat('s', 30), 'android', 'ar');
select pg_temp.login(53);
select public.accept_invite((select token from public.my_invites()));
select pg_temp.login(51);
with created as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.v('ws'), 'Quiet Project', auth.uid()) returning id
) insert into ctx select 'p', id::text from created;
insert into public.project_members (project_id, user_id) values (pg_temp.v('p'), pg_temp.uid(52));
reset role;
insert into ctx select 'pc', id::text from public.conversations where project_id = pg_temp.v('p');

select pg_temp.login(51);
select public.send_message(pg_temp.v('pc'), 'First');
select pg_temp.check(pg_temp.queued('message') = 1, 'a message reaches the phone');

-- 1. Muting a chat.
select pg_temp.login(53);
select pg_temp.fails($$ select public.mute_conversation(pg_temp.v('pc')) $$, 'not_allowed',
  'one cannot mute a chat one is not in');
select pg_temp.login(52);
select pg_temp.fails($$ select public.mute_conversation(pg_temp.v('pc'), now() - interval '1 hour') $$,
  'invalid_date', 'nor until a time already past');
select public.mute_conversation(pg_temp.v('pc'), now() + interval '8 hours');
select pg_temp.check(
  (select until > now() from public.my_muted_conversations(pg_temp.v('ws'))
   where conversation_id = pg_temp.v('pc')),
  'the chat shows as muted, with until when');
select pg_temp.clear();
select pg_temp.login(51);
select public.send_message(pg_temp.v('pc'), 'Second');
select public.send_message(pg_temp.v('pc'), '@Sherif look', p_mentions => array[pg_temp.uid(52)]);
select pg_temp.check(pg_temp.queued('message') = 0, 'a muted chat stays off the phone');
select pg_temp.check(pg_temp.queued('mention') = 1, 'but a mention still comes through');

reset role;
update public.conversation_mutes set until = now() - interval '1 minute';
select pg_temp.login(51);
select public.send_message(pg_temp.v('pc'), 'Third');
select pg_temp.check(pg_temp.queued('message') = 1, 'a mute that ran out is over');
select pg_temp.login(52);
select pg_temp.check(not exists (select 1 from public.my_muted_conversations(pg_temp.v('ws'))),
  'and no longer listed');
select public.mute_conversation(pg_temp.v('pc'));
select public.unmute_conversation(pg_temp.v('pc'));
select pg_temp.clear();
select pg_temp.login(51);
select public.send_message(pg_temp.v('pc'), 'Fourth');
select pg_temp.check(pg_temp.queued('message') = 1, 'unmuting brings messages back');

-- 2. Quiet hours (offset 0, around the current UTC time).
select pg_temp.login(52);
select pg_temp.fails($$ select public.set_quiet_hours('22:00', null, 0) $$, 'invalid_hours',
  'quiet hours need both times');
select public.set_quiet_hours(((now() at time zone 'UTC') - interval '1 hour')::time,
                              ((now() at time zone 'UTC') + interval '1 hour')::time, 0);
select pg_temp.check(
  (select quiet_from is not null and utc_offset = 0 from public.my_notification_settings()),
  'one reads one''s quiet hours back');
select pg_temp.clear();
select pg_temp.login(51);
select public.send_message(pg_temp.v('pc'), 'Late at night');
select pg_temp.check(pg_temp.queued('message') = 0, 'nothing reaches the phone in quiet hours');

select pg_temp.login(52);
select public.set_quiet_hours(((now() at time zone 'UTC') + interval '2 hours')::time,
                              ((now() at time zone 'UTC') + interval '3 hours')::time, 0);
select pg_temp.login(51);
select public.send_message(pg_temp.v('pc'), 'In the day');
select pg_temp.check(pg_temp.queued('message') = 1, 'outside them it does');

select pg_temp.login(52);
select public.set_quiet_hours(null, null, 0);
select pg_temp.check(
  (select quiet_from is null from public.my_notification_settings()), 'quiet hours turned off');

-- 3. Nobody reads anyone else's.
select pg_temp.login(51);
select pg_temp.check(not exists (select 1 from public.my_notification_settings()),
  'one sees only one''s own settings');
select pg_temp.fails($$ select * from public.notification_settings $$, '42501',
  'and not the table');

reset role;
