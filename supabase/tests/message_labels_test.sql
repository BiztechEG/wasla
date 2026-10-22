-- Labels on messages: private to each person, only on messages one reads,
-- and gone from view once the message is.
-- Uses its own users so it does not depend on other test files.

\set ON_ERROR_STOP on

-- Users: Nour (owner), Hadi (in the project), Sami (not in it).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000097', 'nour@labels.example.com', '{"full_name":"Nour"}'),
  ('00000000-0000-0000-0000-000000000098', 'hadi@labels.example.com', '{"full_name":"Hadi"}'),
  ('00000000-0000-0000-0000-000000000099', 'sami@labels.example.com', '{"full_name":"Sami"}');

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
create function pg_temp.count_in(label text) returns int language sql as $$
  select messages from public.my_labels(pg_temp.v('ws')) where name = label $$;

select pg_temp.login(97);
insert into ctx values ('ws', public.create_company_workspace('Labels Co', 'eg', 'Labels Desk'));
insert into public.invites (workspace_id, email, role, invited_by) values
  (pg_temp.v('ws'), 'hadi@labels.example.com', 'member', auth.uid()),
  (pg_temp.v('ws'), 'sami@labels.example.com', 'member', auth.uid());
select pg_temp.login(98);
select public.accept_invite((select token from public.my_invites()));
select pg_temp.login(99);
select public.accept_invite((select token from public.my_invites()));
select pg_temp.login(97);
with created as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.v('ws'), 'Labels Project', auth.uid()) returning id
) insert into ctx select 'p', id::text from created;
insert into public.project_members (project_id, user_id) values (pg_temp.v('p'), pg_temp.uid(98));
reset role;
insert into ctx select 'pc', id::text from public.conversations where project_id = pg_temp.v('p');

select pg_temp.login(97);
insert into ctx values ('m1', public.send_message(pg_temp.v('pc'), 'The contract draft'));
insert into ctx values ('m2', public.send_message(pg_temp.v('pc'), 'Signed copy'));
insert into ctx values ('dm', public.open_direct(pg_temp.v('ws'), pg_temp.uid(98)));
insert into ctx values ('m3', public.send_message(pg_temp.v('dm'), 'Contract price'));

-- 1. Hadi files messages from both chats under a new label, by name.
select pg_temp.login(98);
insert into ctx values ('lc', public.label_message(pg_temp.v('m1'), null, '  Contracts  '));
select pg_temp.check(public.label_message(pg_temp.v('m3'), null, 'contracts') = pg_temp.v('lc'),
  'the same name (any case) is the same label');
select pg_temp.check(public.label_message(pg_temp.v('m2'), pg_temp.v('lc')) = pg_temp.v('lc'),
  'an existing label by its id');
select public.label_message(pg_temp.v('m2'), pg_temp.v('lc'));
select pg_temp.check(
  (select array_agg(name) from public.my_labels(pg_temp.v('ws'))) = array['Contracts']
  and pg_temp.count_in('Contracts') = 3,
  'one label, trimmed, with three messages (labelling twice counts once)');
select pg_temp.check(
  (select array_agg(message_id order by created_at desc)
   from public.labelled(pg_temp.v('lc'))) = array[pg_temp.v('m3'), pg_temp.v('m2'), pg_temp.v('m1')],
  'the label lists messages from every chat, newest first');
select pg_temp.check(
  (select array_agg(message_id order by created_at)
   from public.labelled(pg_temp.v('lc'), pg_temp.v('pc'))) = array[pg_temp.v('m1'), pg_temp.v('m2')],
  'or only one chat''s');
select pg_temp.check(
  (select count(*) from public.chat_labels(pg_temp.v('pc'))) = 2
  and (select count(*) from public.chat_labels(pg_temp.v('dm'))) = 1,
  'a chat knows which of its messages are labelled');
select pg_temp.check(
  (select kind = 'direct' and other_name = 'Nour' from public.labelled(pg_temp.v('lc'))
   where message_id = pg_temp.v('m3')),
  'a private message says who the chat is with');
select pg_temp.fails($$ select public.label_message(pg_temp.v('m1'), null, '   ') $$,
  'invalid_label', 'a label needs a name');
select pg_temp.fails(format('select public.label_message(%L, null, %L)', pg_temp.v('m1'), repeat('x', 41)),
  'invalid_label', 'of at most 40 characters');

-- 2. Labels are private.
select pg_temp.login(97);
select pg_temp.check(
  not exists (select 1 from public.my_labels(pg_temp.v('ws')))
  and not exists (select 1 from public.chat_labels(pg_temp.v('pc')))
  and not exists (select 1 from public.labelled(pg_temp.v('lc'))),
  'nobody else sees one''s labels, not even the sender');
select pg_temp.fails(format('select public.label_message(%L, %L)', pg_temp.v('m1'), pg_temp.v('lc')),
  'not_allowed', 'nor files messages under them');
select pg_temp.fails(format('select public.rename_label(%L, %L)', pg_temp.v('lc'), 'Mine'),
  'not_allowed', 'nor renames them');
select public.unlabel_message(pg_temp.v('m1'), pg_temp.v('lc'));
select public.delete_label(pg_temp.v('lc'));
select pg_temp.login(98);
select pg_temp.check(
  (select name from public.my_labels(pg_temp.v('ws'))) = 'Contracts'
  and pg_temp.count_in('Contracts') = 3,
  'nor takes messages off them or removes them');

-- 3. Only messages one reads can be labelled.
select pg_temp.login(99);
select pg_temp.fails(format('select public.label_message(%L, null, %L)', pg_temp.v('m1'), 'Spy'),
  'not_allowed', 'not a message in a chat one is not in');
select pg_temp.check(not exists (select 1 from public.my_labels(pg_temp.v('ws'))),
  'and no label is left behind');

-- 4. Removing, renaming, deleting.
select pg_temp.login(98);
select public.unlabel_message(pg_temp.v('m2'), pg_temp.v('lc'));
select pg_temp.check(pg_temp.count_in('Contracts') = 2, 'a message comes off a label');
insert into ctx values ('lo', public.label_message(pg_temp.v('m2'), null, 'Other'));
select pg_temp.check(
  (select array_agg(name) from public.my_labels(pg_temp.v('ws'))) = array['Other', 'Contracts'],
  'the most recently used label comes first');
select pg_temp.fails(format('select public.rename_label(%L, %L)', pg_temp.v('lo'), 'CONTRACTS'),
  'label_exists', 'a rename cannot take another label''s name');
select public.rename_label(pg_temp.v('lo'), 'Signed');
select pg_temp.check(
  (select name from public.my_labels(pg_temp.v('ws')) where id = pg_temp.v('lo')) = 'Signed',
  'a label is renamed');
select public.delete_label(pg_temp.v('lo'));
select pg_temp.check(
  (select array_agg(name) from public.my_labels(pg_temp.v('ws'))) = array['Contracts']
  and exists (select 1 from public.conversation_messages(pg_temp.v('pc')) where id = pg_temp.v('m2')),
  'deleting a label leaves its messages');

-- 5. Gone messages drop out: deleted, or in a chat one has left.
select pg_temp.login(97);
select public.delete_message(pg_temp.v('m1'));
select pg_temp.login(98);
select pg_temp.check(pg_temp.count_in('Contracts') = 1
  and not exists (select 1 from public.chat_labels(pg_temp.v('pc'))),
  'a deleted message leaves the label');
select pg_temp.fails(format('select public.label_message(%L, null, %L)', pg_temp.v('m1'), 'Late'),
  'not_allowed', 'and cannot be labelled');
select public.label_message(pg_temp.v('m2'), pg_temp.v('lc'));
select pg_temp.check(pg_temp.count_in('Contracts') = 2, 'back to two');
reset role;
delete from public.project_members where project_id = pg_temp.v('p') and user_id = pg_temp.uid(98);
select pg_temp.login(98);
select pg_temp.check(pg_temp.count_in('Contracts') = 1
  and (select array_agg(message_id) from public.labelled(pg_temp.v('lc'))) = array[pg_temp.v('m3')],
  'messages in a chat one has left drop out of the label');

reset role;
