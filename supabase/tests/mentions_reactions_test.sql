-- @mentions and emoji reactions: who can be mentioned, who is told,
-- the chat list's mention count, and reactions.

\set ON_ERROR_STOP on

-- Users: Hala (owner), Omar and Nour (in the project), Yara (in the
-- workspace, not the project), Tarek (in another workspace).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000991', 'hala@example.com',  '{"full_name":"Hala"}'),
  ('00000000-0000-0000-0000-000000000992', 'omar@example.com',  '{"full_name":"Omar"}'),
  ('00000000-0000-0000-0000-000000000993', 'nour@example.com',  '{"full_name":"Nour"}'),
  ('00000000-0000-0000-0000-000000000994', 'yara@example.com',  '{"full_name":"Yara"}'),
  ('00000000-0000-0000-0000-000000000995', 'tarek@example.com', '{"full_name":"Tarek"}');

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

create function pg_temp.queued(n int, what text) returns bigint language sql security definer as $$
  select count(*) from public.push_outbox
  where user_id = pg_temp.uid(n) and kind = what and sent_at is null $$;
create function pg_temp.mentions(m uuid) returns uuid[] language sql security definer as $$
  select mentions from public.messages where id = m $$;
create function pg_temp.reactions(m uuid) returns jsonb language sql security definer as $$
  select reactions from public.messages where id = m $$;

select pg_temp.login(991);
insert into ctx values ('ws', public.create_company_workspace('Nile', 'eg', 'Nile HQ'));
insert into public.invites (workspace_id, email, role, invited_by) values
  (pg_temp.v('ws'), 'omar@example.com', 'member', auth.uid()),
  (pg_temp.v('ws'), 'nour@example.com', 'member', auth.uid()),
  (pg_temp.v('ws'), 'yara@example.com', 'member', auth.uid());
do $$
begin
  for n in 992..994 loop
    perform pg_temp.login(n);
    perform public.accept_invite((select token from public.my_invites() limit 1));
    perform public.register_push_token('mention-test-phone-' || n, 'android', 'ar');
  end loop;
end $$;
select pg_temp.login(995);
insert into ctx values ('ws2', public.create_company_workspace('Other', 'eg', 'Other HQ'));

select pg_temp.login(991);
select public.register_push_token('mention-test-phone-991', 'android', 'ar');
with p as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.v('ws'), 'Tower', auth.uid()) returning id
)
insert into ctx select 'p', id::text from p;
insert into public.project_members (project_id, user_id, role) values
  (pg_temp.v('p'), pg_temp.uid(992), 'member'),
  (pg_temp.v('p'), pg_temp.uid(993), 'member');
with p as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.v('ws'), 'Annex', auth.uid()) returning id
)
insert into ctx select 'p2', id::text from p;
insert into public.project_members (project_id, user_id, role) values
  (pg_temp.v('p2'), pg_temp.uid(992), 'member');
insert into ctx values ('pc', public.project_conversation(pg_temp.v('p')));

-- 1. Mentions.
select pg_temp.login(992);
insert into ctx values ('m1', public.send_message(pg_temp.v('pc'), '@Nour @Yara @Tarek check this',
  p_mentions => array[pg_temp.uid(993), pg_temp.uid(994), pg_temp.uid(995), pg_temp.uid(992)]));
select pg_temp.check(pg_temp.mentions(pg_temp.v('m1')) = array[pg_temp.uid(993)],
  'only people who can read the chat are kept, never oneself');
select pg_temp.check(pg_temp.queued(993, 'mention') = 1 and pg_temp.queued(993, 'message') = 0,
  'the mentioned person is told they were mentioned, once');
select pg_temp.check(pg_temp.queued(991, 'message') = 1 and pg_temp.queued(991, 'mention') = 0,
  'others get the plain message');
select pg_temp.check(pg_temp.queued(994, 'mention') = 0 and pg_temp.queued(994, 'message') = 0,
  'someone outside the project hears nothing');

insert into ctx values ('m2', public.send_message(pg_temp.v('pc'), 'no one',
  p_mentions => array[pg_temp.uid(994)]));
select pg_temp.check(pg_temp.mentions(pg_temp.v('m2')) is null, 'nobody valid means no mentions');

select pg_temp.login(993);
select pg_temp.check(
  (select unread_mentions = 1 and unread = 2 from public.my_conversations(pg_temp.v('ws'))
   where id = pg_temp.v('pc')),
  'the chat list counts unread mentions');
select pg_temp.check(
  (select mentions = array[pg_temp.uid(993)] and reactions = '{}'::jsonb
   from public.conversation_messages(pg_temp.v('pc')) where id = pg_temp.v('m1')),
  'messages carry their mentions and reactions');
select public.mark_read(pg_temp.v('pc'));
select pg_temp.check(
  (select unread_mentions = 0 from public.my_conversations(pg_temp.v('ws'))
   where id = pg_temp.v('pc')),
  'reading the chat clears them');

-- Private chats: only the other person.
select pg_temp.login(994);
insert into ctx values ('dc', public.open_direct(pg_temp.v('ws'), pg_temp.uid(991)));
insert into ctx values ('m3', public.send_message(pg_temp.v('dc'), '@Hala',
  p_mentions => array[pg_temp.uid(991), pg_temp.uid(992)]));
select pg_temp.check(pg_temp.mentions(pg_temp.v('m3')) = array[pg_temp.uid(991)],
  'a private chat can only mention the other person');
select pg_temp.check(pg_temp.queued(991, 'mention') = 1, 'who is told they were mentioned');

-- 2. Reactions.
select pg_temp.login(991);
select public.toggle_reaction(pg_temp.v('m1'), '👍');
select pg_temp.login(993);
select public.toggle_reaction(pg_temp.v('m1'), '👍');
select public.toggle_reaction(pg_temp.v('m1'), '🎉');
select pg_temp.check(
  pg_temp.reactions(pg_temp.v('m1')) = jsonb_build_object(
    '👍', jsonb_build_array(pg_temp.uid(991)::text, pg_temp.uid(993)::text),
    '🎉', jsonb_build_array(pg_temp.uid(993)::text)),
  'people react with one or more emoji');
select public.toggle_reaction(pg_temp.v('m1'), '🎉');
select pg_temp.check(not pg_temp.reactions(pg_temp.v('m1')) ? '🎉',
  'reacting again takes it back, and an emoji nobody chose goes away');

select pg_temp.fails($$ select public.toggle_reaction(pg_temp.v('m1'), '') $$,
  'invalid_reaction', 'an empty reaction is refused');
select pg_temp.fails($$ select public.toggle_reaction(pg_temp.v('m1'), 'a b') $$,
  'invalid_reaction', 'so is text with spaces');
select pg_temp.fails($$ select public.toggle_reaction(pg_temp.v('m1'), repeat('x', 17)) $$,
  'invalid_reaction', 'or long text');

select pg_temp.login(994);
select pg_temp.fails($$ select public.toggle_reaction(pg_temp.v('m1'), '👍') $$,
  'not_allowed', 'someone outside the chat cannot react');
select pg_temp.login(995);
select pg_temp.fails($$ select public.toggle_reaction(pg_temp.v('m3'), '👍') $$,
  'not_allowed', 'nor someone from another company');

select pg_temp.login(993);
do $$
begin
  for i in 1..20 loop
    perform public.toggle_reaction(pg_temp.v('m2'), 'e' || i);
  end loop;
end $$;
select pg_temp.fails($$ select public.toggle_reaction(pg_temp.v('m2'), 'e21') $$,
  'too_many_reactions', 'twenty different emoji a message at most');
select public.toggle_reaction(pg_temp.v('m2'), 'e20');
select pg_temp.check(not pg_temp.reactions(pg_temp.v('m2')) ? 'e20', 'taking one back still works');

select pg_temp.login(992);
select public.delete_message(pg_temp.v('m2'));
select pg_temp.login(993);
select pg_temp.fails($$ select public.toggle_reaction(pg_temp.v('m2'), '👍') $$,
  'not_allowed', 'a deleted message takes no reactions');
select pg_temp.check(
  (select reactions = '{}'::jsonb and mentions is null
   from public.conversation_messages(pg_temp.v('pc')) where id = pg_temp.v('m2')),
  'and shows none');

select pg_temp.login(991);
update public.projects set status = 'closed' where id = pg_temp.v('p');
select pg_temp.fails($$ select public.toggle_reaction(pg_temp.v('m1'), '❤️') $$,
  'conversation_closed', 'a closed project''s chat takes no reactions');
update public.projects set status = 'active' where id = pg_temp.v('p');

-- 3. Projects in common, for the profile card.
select pg_temp.check(
  array(select public.projects_with(pg_temp.v('ws'), pg_temp.uid(992)))
    = array[pg_temp.v('p2'), pg_temp.v('p')],
  'projects both people are part of, by name');
select pg_temp.check(
  array_length(array(select public.projects_with(pg_temp.v('ws'), pg_temp.uid(994))), 1) is null,
  'none with someone outside them');
select pg_temp.login(993);
select pg_temp.check(
  array(select public.projects_with(pg_temp.v('ws'), pg_temp.uid(992))) = array[pg_temp.v('p')],
  'only projects the viewer is part of');
select pg_temp.login(995);
select pg_temp.check(
  array_length(array(select public.projects_with(pg_temp.v('ws'), pg_temp.uid(992))), 1) is null,
  'and nothing for someone from another company');
select 'all mention and reaction tests passed' as result;
