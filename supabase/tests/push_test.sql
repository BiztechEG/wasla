-- Phone notifications and file cleanup: phones, who gets what, the Edge
-- Functions' key, and which stored files are removed.

\set ON_ERROR_STOP on

-- Users: Mona (owner), Sami and Dina (in the project), Kareem (in the
-- workspace, not the project).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000801', 'mona@example.com',   '{"full_name":"Mona"}'),
  ('00000000-0000-0000-0000-000000000802', 'sami@example.com',   '{"full_name":"Sami"}'),
  ('00000000-0000-0000-0000-000000000803', 'dina@example.com',   '{"full_name":"Dina"}'),
  ('00000000-0000-0000-0000-000000000804', 'kareem@example.com', '{"full_name":"Kareem"}');

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
create function pg_temp.tok(n int, i int default 1) returns text language sql as $$
  select 'fcm-token-for-user-' || n || '-phone-' || i $$;

-- Read as the server, whoever is logged in.
create function pg_temp.queued(n int, what text) returns bigint language sql security definer as $$
  select count(*) from public.push_outbox
  where user_id = pg_temp.uid(n) and kind = what and sent_at is null $$;
create function pg_temp.phones(n int) returns bigint language sql security definer as $$
  select count(*) from public.push_tokens where user_id = pg_temp.uid(n) $$;
create function pg_temp.outbox() returns setof public.push_outbox language sql security definer as $$
  select * from public.push_outbox $$;
create function pg_temp.key() returns text language sql security definer as $$
  select key from public.push_config $$;

select pg_temp.login(801);
insert into ctx values ('ws', public.create_company_workspace('Delta', 'eg', 'Delta HQ'));
insert into public.invites (workspace_id, email, role, invited_by) values
  (pg_temp.v('ws'), 'sami@example.com',   'member', auth.uid()),
  (pg_temp.v('ws'), 'dina@example.com',   'member', auth.uid()),
  (pg_temp.v('ws'), 'kareem@example.com', 'member', auth.uid());
do $$
begin
  for n in 802..804 loop
    perform pg_temp.login(n);
    perform public.accept_invite((select token from public.my_invites() limit 1));
  end loop;
end $$;

select pg_temp.login(801);
with p as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.v('ws'), 'Bridge', auth.uid()) returning id
)
insert into ctx select 'p', id::text from p;
insert into public.project_members (project_id, user_id, role) values
  (pg_temp.v('p'), pg_temp.uid(802), 'member'),
  (pg_temp.v('p'), pg_temp.uid(803), 'member');
insert into ctx values ('pc', public.project_conversation(pg_temp.v('p')));

-- 1. Phones.
select public.register_push_token(pg_temp.tok(801), 'android', 'ar');
select pg_temp.login(802);
select public.register_push_token(pg_temp.tok(802), 'android', 'en');
select pg_temp.login(804);
select public.register_push_token(pg_temp.tok(804), 'android', 'ar');
select pg_temp.check(pg_temp.phones(802) = 1 and pg_temp.phones(804) = 1, 'phones are registered');

select public.register_push_token(pg_temp.tok(804), 'android', 'en');
select pg_temp.check(pg_temp.phones(804) = 1, 'registering again keeps one row');

do $$
begin
  for i in 2..12 loop
    perform public.register_push_token(pg_temp.tok(804, i), 'android', 'ar');
  end loop;
end $$;
select pg_temp.check(pg_temp.phones(804) = 10, 'ten phones a person at most');

-- A phone that signs in to another account moves to it.
select pg_temp.login(803);
select public.register_push_token(pg_temp.tok(804, 12), 'android', 'ar');
select pg_temp.check(pg_temp.phones(803) = 1 and pg_temp.phones(804) = 9,
  'a phone follows whoever signed in on it');

-- Signing out removes only one's own phone.
select public.unregister_push_token(pg_temp.tok(804, 11));
select pg_temp.check(pg_temp.phones(804) = 9, 'nobody can remove someone else''s phone');
select pg_temp.login(804);
select public.unregister_push_token(pg_temp.tok(804, 11));
select pg_temp.check(pg_temp.phones(804) = 8, 'signing out removes the phone');

select pg_temp.fails($$ select count(*) from public.push_tokens $$, '42501',
  'the app cannot read phones directly');
select pg_temp.fails($$ select count(*) from public.push_outbox $$, '42501',
  'or the queue');
select pg_temp.fails($$ select key from public.push_config $$, '42501',
  'or the key');

-- 2. Chat messages: the project's members with phones, never the sender.
select pg_temp.login(802);
select public.send_message(pg_temp.v('pc'), 'Concrete arrives at 7');
select pg_temp.check(pg_temp.queued(801, 'message') = 1, 'the project chat reaches its members');
select pg_temp.check(pg_temp.queued(802, 'message') = 0, 'but not the sender');
select pg_temp.check(pg_temp.queued(803, 'message') = 1, 'Dina has a phone now, so she is told');
select pg_temp.check(pg_temp.queued(804, 'message') = 0, 'nor someone outside the project');
select pg_temp.check(
  (select title = 'Bridge' and actor = 'Sami' and body = 'Concrete arrives at 7'
          and data ->> 'type' = 'chat' and data ->> 'conversation' = pg_temp.v('pc')::text
          and data ->> 'workspace' = pg_temp.v('ws')::text
   from pg_temp.outbox() where user_id = pg_temp.uid(801) and kind = 'message'),
  'it says where, who and what');

-- A private chat reaches the other person only.
select pg_temp.login(804);
insert into ctx values ('dm', public.open_direct(pg_temp.v('ws'), pg_temp.uid(802)));
select public.send_message(pg_temp.v('dm'), 'Got a minute?');
select pg_temp.check(pg_temp.queued(802, 'message') = 1
                     and pg_temp.queued(801, 'message') = 1,
  'a private message reaches only the other person');
select pg_temp.check(
  (select title = 'Kareem' and actor = 'Kareem' from pg_temp.outbox()
   where user_id = pg_temp.uid(802) and kind = 'message'),
  'under the sender''s name');

-- 3. Announcements: their audience, not the author.
select pg_temp.login(801);
select public.post_announcement(pg_temp.v('ws'), null, 'Office closed Thursday');
select pg_temp.check(pg_temp.queued(802, 'announcement') = 1
                     and pg_temp.queued(804, 'announcement') = 1
                     and pg_temp.queued(801, 'announcement') = 0,
  'a workspace announcement reaches everyone else');
select public.post_announcement(pg_temp.v('ws'), pg_temp.v('p'), 'Site visit Sunday');
select pg_temp.check(pg_temp.queued(802, 'announcement') = 2
                     and pg_temp.queued(804, 'announcement') = 1,
  'a project announcement only its members');

-- 4. Task notifications.
insert into ctx values ('t', public.create_task(pg_temp.v('p'), 'Order steel', null,
  array[pg_temp.uid(802)]));
select pg_temp.check(
  (select title = 'Order steel' and actor = 'Mona' and data ->> 'type' = 'task'
          and data ->> 'task' = pg_temp.v('t')::text
   from pg_temp.outbox() where user_id = pg_temp.uid(802) and kind = 'assigned'),
  'being given a task reaches the phone');

-- 5. The push function's key.
select pg_temp.as_server();
select pg_temp.fails($$ select * from public.claim_push_batch('wrong') $$, 'not_allowed',
  'the queue needs the key');
select pg_temp.fails($$ select * from public.claim_push_batch(null) $$, 'not_allowed',
  'not an empty one');
select pg_temp.login(801);
select pg_temp.fails($$ select * from public.claim_push_batch('x') $$, '42501',
  'the app cannot take from the queue');
select pg_temp.fails($$ select public.finish_push_batch('x', '{}', '{}') $$, '42501',
  'or mark it sent');
select pg_temp.fails($$ select * from public.files_to_purge('x') $$, '42501',
  'or list files to remove');

select pg_temp.as_server();
create temp table batch as select * from public.claim_push_batch(pg_temp.key());
select pg_temp.check((select count(*) from batch where token = pg_temp.tok(802)) = 4,
  'each queued notification comes with the phone to send it to');
select pg_temp.check((select count(*) from batch where token like 'fcm-token-for-user-804-%'
                                                and token <> pg_temp.tok(804, 12))
                     = 8, 'one row per phone');
select pg_temp.check(
  (select bool_and(locale = 'en') from batch where token = pg_temp.tok(802)),
  'in the phone''s language');
select pg_temp.check((select count(*) from public.claim_push_batch(pg_temp.key())) = 0,
  'claimed notifications are not handed out twice');

select public.finish_push_batch(pg_temp.key(),
  array(select distinct id from batch where token is distinct from pg_temp.tok(801))::bigint[],
  array[pg_temp.tok(804, 3)]);
select pg_temp.check(pg_temp.phones(804) = 7, 'a phone Firebase no longer knows is removed');
select pg_temp.check(pg_temp.queued(802, 'message') = 0, 'sent notifications are done');
select pg_temp.check(pg_temp.queued(801, 'message') = 1, 'a failed one waits');

-- Retried after two minutes, three times at most, never more than an hour late.
update public.push_outbox set claimed_at = now() - interval '3 minutes'
where user_id = pg_temp.uid(801) and sent_at is null;
select pg_temp.check((select count(*) from public.claim_push_batch(pg_temp.key())) = 1,
  'a failed notification is tried again');
update public.push_outbox set claimed_at = now() - interval '3 minutes'
where user_id = pg_temp.uid(801) and sent_at is null;
select pg_temp.check((select count(*) from public.claim_push_batch(pg_temp.key())) = 1,
  'a third time');
update public.push_outbox set claimed_at = now() - interval '3 minutes'
where user_id = pg_temp.uid(801) and sent_at is null;
select pg_temp.check((select count(*) from public.claim_push_batch(pg_temp.key())) = 0,
  'and then given up');

select pg_temp.login(802);
select public.send_message(pg_temp.v('pc'), 'Old news');
select pg_temp.as_server();
update public.push_outbox set created_at = now() - interval '2 hours' where body = 'Old news';
select pg_temp.check((select count(*) from public.claim_push_batch(pg_temp.key())) = 0,
  'a notification more than an hour old is not sent');
select public.push_tick();
select pg_temp.check((select count(*) from public.push_outbox where body = 'Old news') = 2,
  'the minute job keeps recent rows');
update public.push_outbox set created_at = now() - interval '4 days' where body = 'Old news';
select public.push_tick();
select pg_temp.check(not exists (select 1 from public.push_outbox where body = 'Old news'),
  'and forgets old ones');

-- Someone without phones queues nothing.
delete from public.push_tokens where user_id = pg_temp.uid(803);
select pg_temp.login(802);
select public.send_message(pg_temp.v('pc'), 'Anyone?');
select pg_temp.check(pg_temp.queued(803, 'message') = 0, 'no phone, nothing queued');

-- A message that fails to send queues nothing either.
select pg_temp.login(804);
select pg_temp.fails(format('select public.send_message(%L, %L)', pg_temp.v('pc'), 'hi'),
  'not_allowed', 'someone outside the project cannot write there');
select pg_temp.check(pg_temp.queued(801, 'message') = 2, 'and nobody is told');

-- 6. File cleanup.
select pg_temp.as_server();
insert into storage.objects (bucket_id, name, metadata, created_at) values
  ('files', pg_temp.v('ws') || '/' || pg_temp.uid(802) || '/kept.pdf',    '{"size": 10}', now() - interval '3 days'),
  ('files', pg_temp.v('ws') || '/' || pg_temp.uid(802) || '/deleted.pdf', '{"size": 10}', now() - interval '3 days'),
  ('files', pg_temp.v('ws') || '/' || pg_temp.uid(802) || '/fresh.pdf',   '{"size": 10}', now() - interval '3 days'),
  ('files', pg_temp.v('ws') || '/' || pg_temp.uid(802) || '/orphan.pdf',  '{"size": 10}', now() - interval '3 days'),
  ('files', pg_temp.v('ws') || '/' || pg_temp.uid(802) || '/new.pdf',     '{"size": 10}', now());
insert into public.files (workspace_id, project_id, storage_path, name, mime, size_bytes,
                          uploaded_by, deleted_at)
select pg_temp.v('ws'), pg_temp.v('p'), pg_temp.v('ws') || '/' || pg_temp.uid(802) || '/' || f,
       f, 'application/pdf', 10, pg_temp.uid(802), d
from (values ('kept.pdf', null::timestamptz),
             ('deleted.pdf', now() - interval '2 days'),
             ('fresh.pdf', now())) x(f, d);

select pg_temp.fails($$ select * from public.files_to_purge('wrong') $$, 'not_allowed',
  'cleanup needs the key');
create temp table purge as select * from public.files_to_purge(pg_temp.key());
select pg_temp.check(
  (select array_agg(split_part(path, '/', 3) order by path) from purge
   where path like pg_temp.v('ws') || '/%') = array['deleted.pdf', 'orphan.pdf'],
  'files deleted over a day ago and old unused uploads are removed, nothing else');
select public.mark_files_purged(pg_temp.key(), array(select path from purge));
select pg_temp.check(
  (select count(*) from public.files_to_purge(pg_temp.key())
   where split_part(path, '/', 3) = 'deleted.pdf') = 0,
  'a removed file is not listed again');
select pg_temp.check(
  (select purged_at is null from public.files where name = 'kept.pdf'),
  'a file in use is never marked removed');

-- Voice messages say 🎤 and their length instead of a file name.
select pg_temp.login(804);
insert into storage.objects (bucket_id, name, metadata) values
  ('files', pg_temp.v('ws') || '/' || pg_temp.uid(804) || '/voice.m4a', '{"size": 3000}');
select public.send_message(pg_temp.v('dm'), null,
  p_file_path => pg_temp.v('ws') || '/' || pg_temp.uid(804) || '/voice.m4a',
  p_file_name => 'voice_65s.m4a', p_file_mime => 'audio/mp4', p_file_size => 3000);
select pg_temp.check(
  (select body from pg_temp.outbox() where user_id = pg_temp.uid(802) and kind = 'message'
   order by created_at desc limit 1) = '🎤 1:05',
  'a voice message is announced with its length');

\echo 'all push tests passed'
