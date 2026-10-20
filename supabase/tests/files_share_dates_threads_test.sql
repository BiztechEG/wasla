-- Chat stage 3: files from the Files tab are sent in the chat, the files
-- list says where each came from, the sharing setting, the calendar's days,
-- and reply chains.

\set ON_ERROR_STOP on

-- Users: Mona (owner), Sami and Rana (in the project), Adel (in the
-- workspace, not the project).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000921', 'mona@example.com', '{"full_name":"Mona"}'),
  ('00000000-0000-0000-0000-000000000922', 'sami@example.com', '{"full_name":"Sami"}'),
  ('00000000-0000-0000-0000-000000000923', 'rana@example.com', '{"full_name":"Rana"}'),
  ('00000000-0000-0000-0000-000000000924', 'adel@example.com', '{"full_name":"Adel"}');

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
create function pg_temp.upload(n int, file text) returns void language sql as $$
  insert into storage.objects (bucket_id, name, metadata)
  values ('files', pg_temp.path(n, file), jsonb_build_object('size', 1000)) $$;
-- Moves a message (and its file) back in time, for the calendar.
create function pg_temp.backdate(m uuid, at timestamptz) returns void language sql security definer as $$
  update public.messages set created_at = at where id = m $$;

select pg_temp.login(921);
insert into ctx values ('ws', public.create_company_workspace('Delta', 'eg', 'Delta HQ'));
insert into public.invites (workspace_id, email, role, invited_by) values
  (pg_temp.v('ws'), 'sami@example.com', 'member', auth.uid()),
  (pg_temp.v('ws'), 'rana@example.com', 'member', auth.uid()),
  (pg_temp.v('ws'), 'adel@example.com', 'member', auth.uid());
do $$
begin
  for n in 922..924 loop
    perform pg_temp.login(n);
    perform public.accept_invite((select token from public.my_invites() limit 1));
  end loop;
end $$;

select pg_temp.login(921);
with p as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.v('ws'), 'Bridge', auth.uid()) returning id
)
insert into ctx select 'p', id::text from p;
insert into public.project_members (project_id, user_id, role) values
  (pg_temp.v('p'), pg_temp.uid(922), 'member'),
  (pg_temp.v('p'), pg_temp.uid(923), 'member');
insert into ctx values ('pc', public.project_conversation(pg_temp.v('p')));

-- 1. Files.
select pg_temp.login(922);
select pg_temp.upload(922, 'plan.pdf');
insert into ctx values ('f1', public.add_project_file(pg_temp.v('p'),
  pg_temp.path(922, 'plan.pdf'), 'plan.pdf', 'application/pdf', 1000));
select pg_temp.check(
  (select count(*) = 1 and bool_and(file_from_files) and bool_and(sender_id = pg_temp.uid(922))
   from public.conversation_messages(pg_temp.v('pc')) where file_id = pg_temp.v('f1')),
  'a file added from the Files tab is sent in the project chat, marked as such');

select pg_temp.upload(922, 'photo.jpg');
insert into ctx values ('m1', public.send_message(pg_temp.v('pc'), p_file_path => pg_temp.path(922, 'photo.jpg'),
  p_file_name => 'photo.jpg', p_file_mime => 'image/jpeg', p_file_size => 1000));
insert into ctx values ('dm', public.open_direct(pg_temp.v('ws'), pg_temp.uid(923)));
select pg_temp.upload(922, 'secret.pdf');
insert into ctx values ('m2', public.send_message(pg_temp.v('dm'), p_project => pg_temp.v('p'),
  p_file_path => pg_temp.path(922, 'secret.pdf'), p_file_name => 'secret.pdf',
  p_file_mime => 'application/pdf', p_file_size => 1000));

select pg_temp.check(
  (select source = 'files' and message_id is not null
   from public.project_files(pg_temp.v('p')) where id = pg_temp.v('f1')),
  'the files list says a file came from the Files tab and its message');
select pg_temp.check(
  (select source = 'project' and message_id = pg_temp.v('m1')
   from public.project_files(pg_temp.v('p')) where name = 'photo.jpg'),
  'a project chat file links to its message');
select pg_temp.check(
  (select source = 'direct' and other_name = 'Rana' and message_id = pg_temp.v('m2')
   from public.project_files(pg_temp.v('p')) where name = 'secret.pdf'),
  'a private chat file names the other person');
select pg_temp.login(923);
select pg_temp.check(
  (select other_name = 'Sami' from public.project_files(pg_temp.v('p')) where name = 'secret.pdf'),
  'the other person is the other one for each reader');
select pg_temp.fails(format('select public.delete_file(%L)', pg_temp.v('f1')), 'not_allowed',
  'someone else cannot remove a file they did not add');
select pg_temp.login(922);
select pg_temp.fails(format('select public.delete_file(%L)',
  (select id from public.project_files(pg_temp.v('p')) where name = 'photo.jpg')), 'not_allowed',
  'a chat file goes only with its message');
select public.delete_file(pg_temp.v('f1'));
select pg_temp.check(
  (select deleted from public.conversation_messages(pg_temp.v('pc'))
   where id = (select m.id from public.conversation_messages(pg_temp.v('pc')) m
               where m.deleted order by m.created_at limit 1)),
  'removing a Files tab file takes its chat message with it');
select pg_temp.check(
  not exists (select 1 from public.project_files(pg_temp.v('p')) where id = pg_temp.v('f1')),
  'and it leaves the files list');

-- 2. Sharing outside Wasla.
select pg_temp.login(922);
select pg_temp.check((select allow_sharing from public.workspaces where id = pg_temp.v('ws')),
  'sharing is on by default');
update public.workspaces set allow_sharing = false where id = pg_temp.v('ws');
select pg_temp.check((select allow_sharing from public.workspaces where id = pg_temp.v('ws')),
  'a member cannot turn sharing off');
select pg_temp.login(921);
update public.workspaces set allow_sharing = false where id = pg_temp.v('ws');
select pg_temp.check(not (select allow_sharing from public.workspaces where id = pg_temp.v('ws')),
  'an admin can');

-- 3. Days with messages.
select pg_temp.login(923);
insert into ctx values ('old', public.send_message(pg_temp.v('pc'), 'last month'));
select pg_temp.backdate(pg_temp.v('old'), '2026-09-14 22:30+00');
select pg_temp.check(
  (select array_agg(d) from public.conversation_days(pg_temp.v('pc'), p_utc_offset => 0) d)
    @> array['2026-09-14'::date],
  'the calendar lists the days a chat has messages on');
select pg_temp.check(
  (select array_agg(d) from public.conversation_days(pg_temp.v('pc'), p_utc_offset => 180) d)
    @> array['2026-09-15'::date]
  and not (select array_agg(d) from public.conversation_days(pg_temp.v('pc'), p_utc_offset => 180) d)
    @> array['2026-09-14'::date],
  'in the reader''s own time zone');
select pg_temp.login(924);
select pg_temp.check(not exists (select 1 from public.conversation_days(pg_temp.v('pc'))),
  'someone outside the project sees no days');

-- 4. Reply chains.
select pg_temp.login(921);
insert into ctx values ('root', public.send_message(pg_temp.v('pc'), 'Who takes the site visit?'));
select pg_temp.login(922);
insert into ctx values ('r1', public.send_message(pg_temp.v('pc'), 'Me', p_reply_to => pg_temp.v('root')));
select pg_temp.login(923);
insert into ctx values ('r2', public.send_message(pg_temp.v('pc'), 'With you', p_reply_to => pg_temp.v('r1')));
select pg_temp.login(921);
insert into ctx values ('r3', public.send_message(pg_temp.v('pc'), 'Great', p_reply_to => pg_temp.v('root')));
select public.delete_message(pg_temp.v('r3'));

select pg_temp.login(922);
select pg_temp.check(
  (select reply_count = 2 and repliers = array[pg_temp.uid(923), pg_temp.uid(922)]
   from public.conversation_messages(pg_temp.v('pc')) where id = pg_temp.v('root')),
  'a message counts its replies, replies to replies included, latest repliers first');
select pg_temp.check(
  (select reply_count = 0 from public.conversation_messages(pg_temp.v('pc')) where id = pg_temp.v('r1')),
  'only the message heading a chain counts it');
select pg_temp.check(
  (select array_agg(id order by created_at) = array[pg_temp.v('root'), pg_temp.v('r1'),
                                                    pg_temp.v('r2'), pg_temp.v('r3')]
   from public.reply_chain(pg_temp.v('root'))),
  'the chain lists the message and every reply under it, oldest first');
select pg_temp.login(924);
select pg_temp.check(not exists (select 1 from public.reply_chain(pg_temp.v('root'))),
  'someone outside the project cannot read the chain');
select pg_temp.fails('select * from public.message_rows(array[]::uuid[])', '42501',
  'message rows are not readable directly');

select 'all files, sharing, date and reply chain tests passed' as result;
