-- Phase 2: who can read and write chats, files and announcements.

\set ON_ERROR_STOP on

-- Users: Hala (owner), Omar (project lead), Nour (project member),
-- Samy (member outside the project), Tarek (another company),
-- Yara (project member who leaves), Adel (admin outside the project).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000301', 'hala@example.com',  '{"full_name":"Hala"}'),
  ('00000000-0000-0000-0000-000000000302', 'omar@example.com',  '{"full_name":"Omar"}'),
  ('00000000-0000-0000-0000-000000000303', 'nour@example.com',  '{"full_name":"Nour"}'),
  ('00000000-0000-0000-0000-000000000304', 'samy@example.com',  '{"full_name":"Samy"}'),
  ('00000000-0000-0000-0000-000000000305', 'tarek@example.com', '{"full_name":"Tarek"}'),
  ('00000000-0000-0000-0000-000000000306', 'yara@example.com',  '{"full_name":"Yara"}'),
  ('00000000-0000-0000-0000-000000000307', 'adel@example.com',  '{"full_name":"Adel"}');

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

-- Runs stmt and expects it to fail with the given message or SQLSTATE.
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
create function pg_temp.seen(c text) returns bigint language sql as $$
  select count(*) from public.conversation_messages(pg_temp.v(c)) $$;

-- Hala sets up the workspace and a project.
select pg_temp.login(301);
insert into ctx values ('ws', public.create_company_workspace('Nile', 'eg', 'Nile HQ'));
insert into public.invites (workspace_id, email, role, invited_by) values
  (pg_temp.v('ws'), 'omar@example.com', 'member', auth.uid()),
  (pg_temp.v('ws'), 'nour@example.com', 'member', auth.uid()),
  (pg_temp.v('ws'), 'samy@example.com', 'member', auth.uid()),
  (pg_temp.v('ws'), 'yara@example.com', 'member', auth.uid()),
  (pg_temp.v('ws'), 'adel@example.com', 'admin',  auth.uid());
do $$
begin
  for n in 302..307 loop
    continue when n = 305;
    perform pg_temp.login(n);
    perform public.accept_invite((select token from public.my_invites() limit 1));
  end loop;
end $$;

select pg_temp.login(305);
insert into ctx values ('ws2', public.create_company_workspace('Delta', 'eg', 'Delta'));

select pg_temp.login(301);
with p as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.v('ws'), 'Tower', auth.uid()) returning id
)
insert into ctx select 'p', id::text from p;
insert into public.project_members (project_id, user_id, role) values
  (pg_temp.v('p'), pg_temp.uid(302), 'lead'),
  (pg_temp.v('p'), pg_temp.uid(303), 'member'),
  (pg_temp.v('p'), pg_temp.uid(306), 'member');

-- 1. A new project comes with its group chat.
insert into ctx select 'pc', id::text from public.my_conversations(pg_temp.v('ws')) where kind = 'project';
select pg_temp.check(pg_temp.v('pc') is not null, 'a new project has a group chat');

-- 2. Project chat: members and admins read it; others do not.
select pg_temp.login(302);
insert into ctx values ('m_hello', public.send_message(pg_temp.v('pc'), 'hello team'));
select pg_temp.login(303);
select pg_temp.check(pg_temp.seen('pc') = 1, 'project member reads the project chat');
select pg_temp.login(307);
select pg_temp.check(pg_temp.seen('pc') = 1, 'workspace admin reads every project chat');
select pg_temp.login(304);
select pg_temp.check(pg_temp.seen('pc') = 0, 'member outside the project cannot read its chat');
select pg_temp.check((select count(*) from public.messages) = 0, 'member outside the project sees no messages directly');
select pg_temp.fails(format('select public.send_message(%L, %L)', pg_temp.v('pc'), 'hi'),
  'not_allowed', 'member outside the project cannot post in it');

-- 3. Private chats are private, owners included.
select pg_temp.login(302);
insert into ctx values ('dm', public.open_direct(pg_temp.v('ws'), pg_temp.uid(303)));
insert into ctx values ('m_secret', public.send_message(pg_temp.v('dm'), 'secret plan'));
select pg_temp.login(303);
select pg_temp.check(public.open_direct(pg_temp.v('ws'), pg_temp.uid(302)) = pg_temp.v('dm'),
  'both people get the same private chat');
select pg_temp.check(pg_temp.seen('dm') = 1, 'the other person reads the private chat');
select pg_temp.login(301);
select pg_temp.check(pg_temp.seen('dm') = 0, 'owner cannot read a private chat');
select pg_temp.check(not exists (select 1 from public.messages where conversation_id = pg_temp.v('dm')),
  'owner cannot read private messages directly');
select pg_temp.check(not exists (select 1 from public.my_conversations(pg_temp.v('ws')) where id = pg_temp.v('dm')),
  'private chat is not in the owner''s list');
select pg_temp.check((select count(*) from public.search_messages(pg_temp.v('ws'), 'secret')) = 0,
  'owner cannot find private messages by search');
select pg_temp.fails(format('select public.send_message(%L, %L)', pg_temp.v('dm'), 'hi'),
  'not_allowed', 'owner cannot post in a private chat');
select pg_temp.fails(format('select public.mark_read(%L)', pg_temp.v('dm')),
  'not_allowed', 'owner cannot mark a private chat read');
select pg_temp.login(303);
select pg_temp.check((select count(*) from public.search_messages(pg_temp.v('ws'), 'secret')) = 1,
  'the people in a private chat can search it');

-- 4. Other companies see nothing.
select pg_temp.login(305);
select pg_temp.fails(format('select public.open_direct(%L, %L)', pg_temp.v('ws'), pg_temp.uid(302)),
  'not_allowed', 'outsider cannot start a private chat');
select pg_temp.check(pg_temp.seen('pc') = 0, 'outsider cannot read a project chat');

-- 5. Tagging private messages with a project both people are in.
select pg_temp.login(302);
insert into ctx values ('dm_samy', public.open_direct(pg_temp.v('ws'), pg_temp.uid(304)));
select pg_temp.fails(format('select public.send_message(%L, %L, p_project => %L)',
    pg_temp.v('dm_samy'), 'about Tower', pg_temp.v('p')),
  'invalid_project', 'cannot tag a project the other person is not in');
insert into ctx values ('m_tagged', public.send_message(pg_temp.v('dm'), 'tower drawings', p_project => pg_temp.v('p')));
select pg_temp.check(
  (select count(*) from public.conversation_messages(pg_temp.v('dm'), p_project => pg_temp.v('p'))) = 1,
  'filtering a private chat by project shows only tagged messages');
select pg_temp.login(303);
select pg_temp.check(
  (select pg_temp.v('p') = any (tag_project_ids) from public.my_conversations(pg_temp.v('ws'))
   where id = pg_temp.v('dm')),
  'chat list knows which projects a private chat touches');

-- 6. Unread counts.
select pg_temp.check(
  (select unread from public.my_conversations(pg_temp.v('ws')) where id = pg_temp.v('dm')) = 2,
  'two unread messages before opening');
select public.mark_read(pg_temp.v('dm'));
select pg_temp.check(
  (select unread from public.my_conversations(pg_temp.v('ws')) where id = pg_temp.v('dm')) = 0,
  'nothing unread after opening');
select pg_temp.login(302);
select pg_temp.check(
  exists (select 1 from public.conversation_reads
          where conversation_id = pg_temp.v('dm') and user_id = pg_temp.uid(303)),
  'the sender can see the chat was read');
select pg_temp.login(303);

-- 7. Replies stay in their chat.
select pg_temp.fails(format('select public.send_message(%L, %L, p_reply_to => %L)',
    pg_temp.v('dm'), 'reply', pg_temp.v('m_hello')),
  'invalid_reply', 'cannot reply to a message from another chat');
select public.send_message(pg_temp.v('dm'), 'got it', p_reply_to => pg_temp.v('m_secret'));
select pg_temp.check(
  (select reply_body from public.conversation_messages(pg_temp.v('dm')) where body = 'got it') = 'secret plan',
  'a reply carries the quoted message');

-- 8. Files.
select pg_temp.login(302);
insert into storage.objects (bucket_id, name) values
  ('files', pg_temp.path(302, 'plan.pdf')),
  ('files', pg_temp.path(302, 'site.png'));
select pg_temp.fails(format('insert into storage.objects (bucket_id, name) values (%L, %L)',
    'files', pg_temp.path(303, 'x.pdf')),
  '42501', 'cannot upload into someone else''s folder');
select pg_temp.fails(format('insert into storage.objects (bucket_id, name) values (%L, %L)',
    'files', pg_temp.v('ws2') || '/' || pg_temp.uid(302) || '/x.pdf'),
  '42501', 'cannot upload into another company''s workspace');
insert into ctx values ('m_pdf', public.send_message(pg_temp.v('dm'), null, p_project => pg_temp.v('p'),
  p_file_path => pg_temp.path(302, 'plan.pdf'), p_file_name => 'المخطط.pdf',
  p_file_mime => 'application/pdf', p_file_size => 2400000));
select public.send_message(pg_temp.v('pc'), 'site photo',
  p_file_path => pg_temp.path(302, 'site.png'), p_file_name => 'site.png',
  p_file_mime => 'image/png', p_file_size => 800000);
select pg_temp.fails(format('select public.send_message(%L, p_file_path => %L, p_file_size => 1)',
    pg_temp.v('pc'), pg_temp.path(303, 'x.pdf')),
  'invalid_file', 'cannot attach someone else''s upload');
select pg_temp.fails(format('select public.send_message(%L, p_file_path => %L, p_file_size => 60000000)',
    pg_temp.v('pc'), pg_temp.path(302, 'big.zip')),
  'file_too_large', 'files over 50 MB are refused');

select pg_temp.login(303);
select pg_temp.check((select count(*) from public.project_files(pg_temp.v('p'))) = 2,
  'project files include a private chat''s tagged file for its two people');
select pg_temp.check((select count(*) from storage.objects where name = pg_temp.path(302, 'plan.pdf')) = 1,
  'the other person can download a private chat''s file');
select pg_temp.login(301);
select pg_temp.check((select count(*) from public.project_files(pg_temp.v('p'))) = 1,
  'others in the project see only the project chat''s file');
select pg_temp.check((select count(*) from storage.objects where name = pg_temp.path(302, 'plan.pdf')) = 0,
  'owner cannot download a private chat''s file');
select pg_temp.check((select count(*) from storage.objects where name = pg_temp.path(302, 'site.png')) = 1,
  'project member downloads the project chat''s file');
select pg_temp.login(304);
select pg_temp.check((select count(*) from storage.objects) = 0,
  'member outside the project downloads nothing');

-- 9. Deleting messages.
select pg_temp.login(303);
select pg_temp.fails(format('select public.delete_message(%L)', pg_temp.v('m_pdf')),
  'not_allowed', 'cannot delete someone else''s private message');
insert into ctx values ('m_oops', public.send_message(pg_temp.v('pc'), 'oops'));
select pg_temp.fails(format('select public.delete_message(%L)', pg_temp.v('m_hello')),
  'not_allowed', 'project member cannot delete others'' messages');
select pg_temp.login(302);
select public.delete_message(pg_temp.v('m_oops'));
select pg_temp.check(
  (select deleted and body is null from public.conversation_messages(pg_temp.v('pc'))
   where id = pg_temp.v('m_oops')),
  'project lead removes a message from the project chat');
select public.delete_message(pg_temp.v('m_pdf'));
select pg_temp.login(303);
select pg_temp.check(
  (select deleted and file_name is null from public.conversation_messages(pg_temp.v('dm'))
   where id = pg_temp.v('m_pdf')),
  'a deleted message hides its file');
select pg_temp.check((select count(*) from public.project_files(pg_temp.v('p'))) = 1,
  'a deleted message''s file leaves the project files');
select pg_temp.check((select count(*) from storage.objects where name = pg_temp.path(302, 'plan.pdf')) = 0,
  'a deleted message''s file can no longer be downloaded');

-- 10. Someone leaving loses access, and their messages keep their name.
select pg_temp.login(306);
select public.send_message(pg_temp.v('pc'), 'bye all');
insert into ctx values ('dm_yara', public.open_direct(pg_temp.v('ws'), pg_temp.uid(302)));
select public.send_message(pg_temp.v('dm_yara'), 'thanks Omar');
select pg_temp.login(301);
update public.workspace_members set status = 'inactive' where user_id = pg_temp.uid(306);
select pg_temp.login(306);
select pg_temp.check(pg_temp.seen('pc') = 0 and pg_temp.seen('dm_yara') = 0,
  'someone who left reads none of the workspace''s chats');
select pg_temp.fails(format('select public.send_message(%L, %L)', pg_temp.v('pc'), 'hi'),
  'not_allowed', 'someone who left cannot post');
select pg_temp.login(302);
select pg_temp.check(
  (select sender_name from public.conversation_messages(pg_temp.v('pc')) where body = 'bye all') = 'Yara',
  'messages keep the name of someone who left');
select pg_temp.check(
  (select not other_active from public.my_conversations(pg_temp.v('ws')) where id = pg_temp.v('dm_yara')),
  'chat list shows the other person has left');
select pg_temp.fails(format('select public.send_message(%L, %L)', pg_temp.v('dm_yara'), 'hi'),
  'conversation_closed', 'cannot write to someone who left');

-- 11. Closed projects are read-only.
select pg_temp.login(301);
update public.projects set status = 'closed' where id = pg_temp.v('p');
select pg_temp.login(302);
select pg_temp.fails(format('select public.send_message(%L, %L)', pg_temp.v('pc'), 'hi'),
  'conversation_closed', 'cannot post in a closed project');
select pg_temp.check(pg_temp.seen('pc') > 0, 'a closed project''s chat stays readable');
select pg_temp.login(301);
update public.projects set status = 'active' where id = pg_temp.v('p');

-- 12. Announcements.
select pg_temp.login(303);
select pg_temp.fails(format('select public.post_announcement(%L, %L, %L)', pg_temp.v('ws'), pg_temp.v('p'), 'x'),
  'not_allowed', 'project member cannot post announcements');
select pg_temp.login(302);
insert into ctx values ('a1', public.post_announcement(pg_temp.v('ws'), pg_temp.v('p'), 'Site visit Tuesday', true));
select pg_temp.login(304);
select pg_temp.check((select count(*) from public.announcements_for(pg_temp.v('ws'), pg_temp.v('p'))) = 0,
  'people outside the project do not see its announcements');
select pg_temp.login(303);
select pg_temp.check(exists (select 1 from public.unread_announcements(pg_temp.v('ws')) where id = pg_temp.v('a1')),
  'a new announcement shows as unread');
select public.mark_announcements_read(array[pg_temp.v('a1')]);
select pg_temp.check(not exists (select 1 from public.unread_announcements(pg_temp.v('ws')) where id = pg_temp.v('a1')),
  'reading an announcement clears it');
select pg_temp.login(302);
select pg_temp.check(
  (select read_count = 1 and audience = 2 from public.announcements_for(pg_temp.v('ws'), pg_temp.v('p'))
   where id = pg_temp.v('a1')),
  'the poster sees 1 of 2 people read it');

select pg_temp.login(303);
select pg_temp.fails(format('select public.post_announcement(%L, null, %L)', pg_temp.v('ws'), 'x'),
  'not_allowed', 'members cannot post to the whole workspace');
select pg_temp.login(307);
insert into ctx values ('a2', public.post_announcement(pg_temp.v('ws'), null, 'Office closed Thursday'));
select pg_temp.login(304);
select pg_temp.check((select count(*) from public.announcements_for(pg_temp.v('ws'), null)) = 1,
  'everyone in the workspace sees workspace announcements');
select pg_temp.login(305);
select pg_temp.check((select count(*) from public.announcements_for(pg_temp.v('ws'), null)) = 0,
  'other companies do not');
select public.mark_announcements_read(array[pg_temp.v('a2')]);
select pg_temp.login(303);
select pg_temp.fails(format('select public.delete_announcement(%L)', pg_temp.v('a2')),
  'not_allowed', 'members cannot delete announcements');
select pg_temp.login(302);
select public.delete_announcement(pg_temp.v('a1'));
select pg_temp.check((select count(*) from public.announcements_for(pg_temp.v('ws'), pg_temp.v('p'))) = 0,
  'the poster deletes their announcement');

-- 13. Search folds Arabic letter variants and treats % as text.
select pg_temp.login(303);
select public.send_message(pg_temp.v('pc'), 'مدرسة الإسكندرية');
select pg_temp.login(301);
select pg_temp.check((select count(*) from public.search_messages(pg_temp.v('ws'), 'مدرسه الاسكندريه')) = 1,
  'search matches ة/ه and إ/ا');
select pg_temp.check((select count(*) from public.search_messages(pg_temp.v('ws'), '%%')) = 0,
  'search ignores % wildcards');

-- 14. Limits and direct writes.
select pg_temp.fails(format('select public.send_message(%L, %L)', pg_temp.v('pc'), '   '),
  'empty_message', 'empty messages are refused');
select pg_temp.fails(format('select public.send_message(%L, %L)', pg_temp.v('pc'), repeat('x', 4001)),
  '23514', 'messages are capped at 4000 characters');
select pg_temp.fails(format('insert into public.messages (conversation_id, workspace_id, sender_id, body) values (%L, %L, %L, %L)',
    pg_temp.v('pc'), pg_temp.v('ws'), auth.uid(), 'x'),
  '42501', 'messages cannot be written directly');
select pg_temp.fails('select * from public.conversations', '42501', 'conversations are not readable directly');
select pg_temp.fails('select * from public.files', '42501', 'files are not readable directly');
do $$
begin
  for i in 1..61 loop
    perform public.send_message(pg_temp.v('pc'), 'msg ' || i);
  end loop;
  raise exception 'FAILED: 61 messages in a minute';
exception when raise_exception then
  if sqlerrm <> 'too_many_requests' then raise; end if;
  raise notice 'ok: sending is rate limited';
end $$;

-- 15. Live updates.
reset role;
select pg_temp.check(
  (select count(*) from pg_publication_tables
   where pubname = 'supabase_realtime' and tablename in ('messages', 'conversation_reads')) = 2,
  'messages and read state are published for live updates');

\echo 'all chat tests passed'
