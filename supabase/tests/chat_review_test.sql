-- Phase 2 review: storage limits, closed projects, read state, search.

\set ON_ERROR_STOP on

-- Users: Lina (owner), Karim (project member), Dina (outside the project),
-- Fady (added to the project later).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000401', 'lina@example.com',  '{"full_name":"Lina"}'),
  ('00000000-0000-0000-0000-000000000402', 'karim@example.com', '{"full_name":"Karim"}'),
  ('00000000-0000-0000-0000-000000000403', 'dina@example.com',  '{"full_name":"Dina"}'),
  ('00000000-0000-0000-0000-000000000404', 'fady@example.com',  '{"full_name":"Fady"}');

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
create function pg_temp.path(n int, file text) returns text language sql as $$
  select pg_temp.v('ws') || '/' || pg_temp.uid(n) || '/' || file $$;
-- Stores an object as the signed-in user, as the Storage API would.
create function pg_temp.upload(n int, file text, size bigint) returns void language sql as $$
  insert into storage.objects (bucket_id, name, metadata)
  values ('files', pg_temp.path(n, file), jsonb_build_object('size', size)) $$;

select pg_temp.login(401);
insert into ctx values ('ws', public.create_company_workspace('Sinai', 'eg', 'Sinai HQ'));
insert into public.invites (workspace_id, email, role, invited_by) values
  (pg_temp.v('ws'), 'karim@example.com', 'member', auth.uid()),
  (pg_temp.v('ws'), 'dina@example.com',  'member', auth.uid()),
  (pg_temp.v('ws'), 'fady@example.com',  'member', auth.uid());
do $$
begin
  for n in 402..404 loop
    perform pg_temp.login(n);
    perform public.accept_invite((select token from public.my_invites() limit 1));
  end loop;
end $$;

select pg_temp.login(401);
with p as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.v('ws'), 'Dock', auth.uid()) returning id
)
insert into ctx select 'p', id::text from p;
insert into public.project_members (project_id, user_id, role) values
  (pg_temp.v('p'), pg_temp.uid(402), 'member');
insert into ctx values ('pc', public.project_conversation(pg_temp.v('p')));

-- 1. A file's size comes from the stored object.
select pg_temp.login(402);
select pg_temp.upload(402, 'a.pdf', 3000000);
insert into ctx values ('m_file', public.send_message(pg_temp.v('pc'), null,
  p_file_path => pg_temp.path(402, 'a.pdf'), p_file_name => 'a.pdf', p_file_size => 0));
select pg_temp.check(
  (select file_size from public.conversation_messages(pg_temp.v('pc')) where id = pg_temp.v('m_file')) = 3000000,
  'the stored size is recorded, not the size the app claims');
select pg_temp.fails(format('select public.send_message(%L, p_file_path => %L, p_file_size => 1)',
    pg_temp.v('pc'), pg_temp.path(402, 'never-uploaded.pdf')),
  'invalid_file', 'a file that was never uploaded cannot be attached');

-- 2. Removing one's own uploads that nothing uses.
select pg_temp.upload(402, 'spare.pdf', 1000);
delete from storage.objects where name = pg_temp.path(402, 'spare.pdf');
select pg_temp.check((select count(*) from storage.objects where name = pg_temp.path(402, 'spare.pdf')) = 0,
  'an unused upload can be removed by its uploader');
delete from storage.objects where name = pg_temp.path(402, 'a.pdf');
select pg_temp.check((select count(*) from storage.objects where name = pg_temp.path(402, 'a.pdf')) = 1,
  'a file a message still uses cannot be removed');
select pg_temp.login(401);
select pg_temp.upload(401, 'lina.pdf', 1000);
select pg_temp.login(402);
delete from storage.objects where name = pg_temp.path(401, 'lina.pdf');
select pg_temp.login(401);
select pg_temp.check((select count(*) from storage.objects where name = pg_temp.path(401, 'lina.pdf')) = 1,
  'nobody removes someone else''s upload');
select pg_temp.login(402);
select public.delete_message(pg_temp.v('m_file'));
delete from storage.objects where name = pg_temp.path(402, 'a.pdf');
select pg_temp.check((select count(*) from storage.objects where name = pg_temp.path(402, 'a.pdf')) = 0,
  'a deleted message''s file can be removed by its uploader');

-- 3. Daily upload allowance per person and workspace.
select pg_temp.upload(402, 'huge-1.bin', 2147483648);
select pg_temp.fails(format('insert into storage.objects (bucket_id, name, metadata) values (%L, %L, %L)',
    'files', pg_temp.path(402, 'huge-2.bin'), '{"size": 10}'),
  '42501', 'uploads stop after 2 GB in a day');
delete from storage.objects where name = pg_temp.path(402, 'huge-1.bin');

-- 4. The plan's storage counts everything uploaded, sent or not.
reset role;
insert into public.plans (id, name, max_members, storage_gb) values ('tiny', 'Tiny', 10, 1);
update public.workspaces set plan_id = 'tiny' where id = pg_temp.v('ws');
select pg_temp.login(401);
select pg_temp.upload(401, 'big-1.bin', 1050000000);
select pg_temp.upload(401, 'big-2.bin', 40000000);
select pg_temp.fails(format('select public.add_project_file(%L, %L, %L, %L, %L)',
    pg_temp.v('p'), pg_temp.path(401, 'big-2.bin'), 'big-2.bin', 'application/zip', 1),
  'storage_full', 'a file that takes the workspace over its plan is refused');
select pg_temp.fails(format('insert into storage.objects (bucket_id, name, metadata) values (%L, %L, %L)',
    'files', pg_temp.path(401, 'big-3.bin'), '{"size": 10}'),
  '42501', 'uploads stop once the workspace is full, sent or not');
delete from storage.objects where name in (pg_temp.path(401, 'big-1.bin'), pg_temp.path(401, 'big-2.bin'));
reset role;
update public.workspaces set plan_id = 'free' where id = pg_temp.v('ws');

-- 5. Adding files is rate limited.
select pg_temp.login(402);
do $$
begin
  for i in 1..31 loop
    perform pg_temp.upload(402, 'r' || i || '.txt', 10);
    perform public.add_project_file(pg_temp.v('p'), pg_temp.path(402, 'r' || i || '.txt'),
                                    'r.txt', 'text/plain', 10);
  end loop;
  raise exception 'FAILED: 31 files in a minute';
exception when raise_exception then
  if sqlerrm <> 'too_many_requests' then raise; end if;
  raise notice 'ok: adding files is rate limited';
end $$;

-- 6. Chat list details.
insert into ctx values ('m_last', public.send_message(pg_temp.v('pc'), 'last words'));
select pg_temp.check(
  (select other_active from public.my_conversations(pg_temp.v('ws')) where id = pg_temp.v('pc')),
  'a project chat is never shown as someone who left');
select pg_temp.upload(402, 'b.pdf', 2000);
insert into ctx values ('m_b', public.send_message(pg_temp.v('pc'), null,
  p_file_path => pg_temp.path(402, 'b.pdf'), p_file_name => 'salaries.xlsx'));
select public.delete_message(pg_temp.v('m_b'));
select pg_temp.check(
  (select last_deleted and last_file_name is null from public.my_conversations(pg_temp.v('ws'))
   where id = pg_temp.v('pc')),
  'a deleted last message does not show its file name in the list');
select pg_temp.check(
  (select count(*) > 0 and bool_and(workspace_id = pg_temp.v('ws')) from public.conversation_reads
   where conversation_id = pg_temp.v('pc')),
  'read state records its workspace');

-- 7. Someone added to a project starts with its chat read.
select pg_temp.login(401);
insert into public.project_members (project_id, user_id, role) values
  (pg_temp.v('p'), pg_temp.uid(404), 'member');
select pg_temp.login(404);
select pg_temp.check(
  (select unread from public.my_conversations(pg_temp.v('ws')) where id = pg_temp.v('pc')) = 0,
  'a new project member does not see the whole history as unread');
select pg_temp.login(402);
select public.send_message(pg_temp.v('pc'), 'welcome Fady');
select pg_temp.login(404);
select pg_temp.check(
  (select unread from public.my_conversations(pg_temp.v('ws')) where id = pg_temp.v('pc')) = 1,
  'and sees new messages as unread');

-- 8. Projects a private message can be tagged with.
select pg_temp.login(402);
insert into ctx values ('dm_kd', public.open_direct(pg_temp.v('ws'), pg_temp.uid(403)));
insert into ctx values ('dm_kf', public.open_direct(pg_temp.v('ws'), pg_temp.uid(404)));
select pg_temp.check((select count(*) from public.shared_projects(pg_temp.v('dm_kd'))) = 0,
  'no tags with someone outside the project');
select pg_temp.check((select array_agg(x) from public.shared_projects(pg_temp.v('dm_kf')) x) = array[pg_temp.v('p')],
  'tags offer projects both people are in');
select pg_temp.login(401);
select pg_temp.check((select count(*) from public.shared_projects(pg_temp.v('dm_kf'))) = 0,
  'outsiders learn nothing about a private chat');

-- 9. Search.
select pg_temp.login(402);
select public.send_message(pg_temp.v('dm_kf'), 'تقرير المسؤول', p_project => pg_temp.v('p'));
select pg_temp.check((select count(*) from public.search_messages(pg_temp.v('ws'), 'مسئول')) = 1,
  'search matches ؤ and ئ');
select pg_temp.check(
  (select kind = 'direct' and other_name = 'Fady' from public.search_messages(pg_temp.v('ws'), 'مسئول')),
  'a search hit says which chat it is in');
select pg_temp.check((select count(*) from public.search_messages(pg_temp.v('ws'), 'ـــ')) = 0,
  'a search of only marks finds nothing');
select pg_temp.login(401);
select pg_temp.check((select count(*) from public.search_messages(pg_temp.v('ws'), 'مسئول')) = 0,
  'owner''s search does not reach private chats');
select pg_temp.check((select count(*) from public.messages where conversation_id = pg_temp.v('dm_kf')) = 0,
  'owner cannot read private messages directly');

-- 10. Closed projects are read-only.
select pg_temp.login(402);
insert into ctx values ('m_keep', public.send_message(pg_temp.v('pc'), 'keep me'));
select pg_temp.upload(402, 'c.pdf', 2000);
insert into ctx values ('f_c', public.add_project_file(pg_temp.v('p'), pg_temp.path(402, 'c.pdf'),
  'c.pdf', 'application/pdf', 2000));
select pg_temp.login(401);
insert into ctx values ('a_p', public.post_announcement(pg_temp.v('ws'), pg_temp.v('p'), 'Dock opens'));
update public.projects set status = 'closed' where id = pg_temp.v('p');
select pg_temp.fails(format('select public.delete_message(%L)', pg_temp.v('m_keep')),
  'conversation_closed', 'messages stay in a closed project');
select pg_temp.fails(format('select public.delete_file(%L)', pg_temp.v('f_c')),
  'conversation_closed', 'files stay in a closed project');
select pg_temp.fails(format('select public.set_file_pinned(%L, true)', pg_temp.v('f_c')),
  'conversation_closed', 'files are not pinned in a closed project');
select pg_temp.fails(format('select public.set_announcement_pinned(%L, true)', pg_temp.v('a_p')),
  'conversation_closed', 'announcements are not pinned in a closed project');
select pg_temp.fails(format('select public.delete_announcement(%L)', pg_temp.v('a_p')),
  'conversation_closed', 'announcements stay in a closed project');

-- 11. Live updates follow the same read rules, checked once per query.
select pg_temp.login(403);
select pg_temp.check((select count(*) from public.messages) = 0,
  'someone outside the project and the private chats reads no messages');
select pg_temp.check((select count(*) from public.conversation_reads) = 0,
  'nor their read state');

\echo 'all chat review tests passed'
