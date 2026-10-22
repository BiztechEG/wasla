-- Polls and pinned messages: who votes, who closes, who pins.
-- Uses its own users so it does not depend on other test files.

\set ON_ERROR_STOP on

-- Users: Laila (owner, runs the project), Tarek and Ziad (members of it).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000076', 'laila@polls.example.com', '{"full_name":"Laila"}'),
  ('00000000-0000-0000-0000-000000000077', 'tarek@polls.example.com', '{"full_name":"Tarek"}'),
  ('00000000-0000-0000-0000-000000000078', 'ziad@polls.example.com',  '{"full_name":"Ziad"}');

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
create function pg_temp.poll() returns jsonb language sql as $$
  select poll from public.conversation_messages(pg_temp.v('pc'))
  where id = pg_temp.v('m') $$;
create function pg_temp.votes(opt int) returns int language sql as $$
  select coalesce(jsonb_array_length(pg_temp.poll() -> 'votes' -> opt::text), 0) $$;

select pg_temp.login(76);
insert into ctx values ('ws', public.create_company_workspace('Polls Co', 'eg', 'Polls Desk'));
insert into public.invites (workspace_id, email, role, invited_by) values
  (pg_temp.v('ws'), 'tarek@polls.example.com', 'member', auth.uid()),
  (pg_temp.v('ws'), 'ziad@polls.example.com', 'member', auth.uid());
select pg_temp.login(77);
select public.accept_invite((select token from public.my_invites()));
select pg_temp.login(78);
select public.accept_invite((select token from public.my_invites()));
select pg_temp.login(76);
with created as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.v('ws'), 'Polls Project', auth.uid()) returning id
) insert into ctx select 'p', id::text from created;
insert into public.project_members (project_id, user_id) values
  (pg_temp.v('p'), pg_temp.uid(77)), (pg_temp.v('p'), pg_temp.uid(78));
reset role;
insert into ctx select 'pc', id::text from public.conversations where project_id = pg_temp.v('p');

-- 1. Tarek asks; options are trimmed and checked.
select pg_temp.login(77);
select pg_temp.fails($$ select public.create_poll(pg_temp.v('pc'), 'Lunch?', array['Yes', ' ']) $$,
  'invalid_poll', 'a poll needs two options');
insert into ctx values ('m', public.create_poll(pg_temp.v('pc'), 'Meeting day?',
  array[' Sunday ', 'Monday', 'Tuesday']));
select pg_temp.check(
  (select body = 'Meeting day?' from public.conversation_messages(pg_temp.v('pc'))
   where id = pg_temp.v('m'))
  and pg_temp.poll() -> 'options' = '["Sunday", "Monday", "Tuesday"]'::jsonb,
  'the question is the message, with its options');

-- 2. Votes.
select public.vote_poll(pg_temp.v('m'), array[0]);
select pg_temp.fails($$ select public.vote_poll(pg_temp.v('m'), array[0, 1]) $$,
  'invalid_vote', 'one option only, unless it allows more');
select pg_temp.fails($$ select public.vote_poll(pg_temp.v('m'), array[5]) $$,
  'invalid_vote', 'no option that is not there');
select pg_temp.login(78);
select public.vote_poll(pg_temp.v('m'), array[0]);
select pg_temp.check(pg_temp.votes(0) = 2, 'two votes for Sunday');
select public.vote_poll(pg_temp.v('m'), array[1]);
select pg_temp.check(pg_temp.votes(0) = 1 and pg_temp.votes(1) = 1, 'changing one''s vote moves it');
select public.vote_poll(pg_temp.v('m'), '{}');
select pg_temp.check(pg_temp.votes(1) = 0 and pg_temp.poll() -> 'votes' ? '0',
  'and none takes it back');

-- 3. Closing: not Ziad's to close; Laila runs the project.
select pg_temp.fails($$ select public.close_poll(pg_temp.v('m')) $$, 'not_allowed',
  'only whoever asked closes it');
select pg_temp.login(76);
select public.close_poll(pg_temp.v('m'));
select pg_temp.login(78);
select pg_temp.fails($$ select public.vote_poll(pg_temp.v('m'), array[2]) $$, 'poll_closed',
  'a closed poll takes no votes');

-- 4. Pinning in the project's chat is for whoever runs it.
select pg_temp.check(
  (select not can_pin and message_id is null from public.conversation_pin(pg_temp.v('pc'))),
  'nothing pinned, and a member may not pin');
select pg_temp.fails($$ select public.pin_message(pg_temp.v('m')) $$, 'not_allowed',
  'so a member cannot');
select pg_temp.login(76);
select public.pin_message(pg_temp.v('m'));
select pg_temp.login(78);
select pg_temp.check(
  (select message_id = pg_temp.v('m') and body = 'Meeting day?' and pinned_by_name = 'Laila'
   from public.conversation_pin(pg_temp.v('pc'))),
  'everyone sees the pinned message');
select pg_temp.login(76);
select public.pin_message(pg_temp.v('m'), false);
select pg_temp.check(
  (select message_id is null from public.conversation_pin(pg_temp.v('pc'))), 'and it comes down');

-- 5. In a private chat, either person pins.
select pg_temp.login(77);
insert into ctx values ('dm', public.open_direct(pg_temp.v('ws'), pg_temp.uid(78)));
insert into ctx values ('dmm', public.send_message(pg_temp.v('dm'), 'The address'));
select pg_temp.login(78);
select public.pin_message(pg_temp.v('dmm'));
select pg_temp.check(
  (select message_id = pg_temp.v('dmm') from public.conversation_pin(pg_temp.v('dm'))),
  'either person pins in a private chat');
select pg_temp.login(76);
select pg_temp.check(not exists (select 1 from public.conversation_pin(pg_temp.v('dm'))),
  'nobody else sees it');

reset role;
