-- Announcements that ask for confirmation, and who has read them.

\set ON_ERROR_STOP on

-- Users: Hala (owner), Omar and Tamer (in the project), Sara (outside it).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000961', 'hala2@example.com',  '{"full_name":"Hala"}'),
  ('00000000-0000-0000-0000-000000000962', 'omar2@example.com',  '{"full_name":"Omar"}'),
  ('00000000-0000-0000-0000-000000000963', 'sara2@example.com',  '{"full_name":"Sara"}'),
  ('00000000-0000-0000-0000-000000000964', 'tamer2@example.com', '{"full_name":"Tamer"}');

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

select pg_temp.login(961);
insert into ctx values ('ws', public.create_company_workspace('Aswan', 'eg', 'Aswan Office'));
insert into public.invites (workspace_id, email, role, invited_by) values
  (pg_temp.v('ws'), 'omar2@example.com', 'member', auth.uid()),
  (pg_temp.v('ws'), 'sara2@example.com',  'member', auth.uid()),
  (pg_temp.v('ws'), 'tamer2@example.com',  'member', auth.uid());
do $$
begin
  for n in 962..964 loop
    perform pg_temp.login(n);
    perform public.accept_invite((select token from public.my_invites() limit 1));
  end loop;
end $$;

select pg_temp.login(961);
with p as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.v('ws'), 'Dock', auth.uid()) returning id
)
insert into ctx select 'p', id::text from p;
insert into public.project_members (project_id, user_id, role) values
  (pg_temp.v('p'), pg_temp.uid(962), 'member');
insert into ctx values ('pc', public.project_conversation(pg_temp.v('p')));


select pg_temp.login(961);
insert into public.project_members (project_id, user_id, role) values
  (pg_temp.v('p'), pg_temp.uid(964), 'member');

insert into ctx values ('a', public.post_announcement(pg_temp.v('ws'), pg_temp.v('p'),
  'Safety briefing at 8', p_needs_ack => true));
insert into ctx values ('plain', public.post_announcement(pg_temp.v('ws'), pg_temp.v('p'), 'Lunch at 1'));

-- Omar opens both: read, but one still waits for his confirmation.
select pg_temp.login(962);
select public.mark_announcements_read(array[pg_temp.v('a'), pg_temp.v('plain')]);
select pg_temp.check(
  (select count(*) from public.unread_announcements(pg_temp.v('ws')) where id = pg_temp.v('a') and needs_ack) = 1,
  'a read announcement that asks for confirmation stays on top of the chats');
select pg_temp.check(
  (select count(*) from public.unread_announcements(pg_temp.v('ws')) where id = pg_temp.v('plain')) = 0,
  'a plain one leaves once read');
select pg_temp.fails(format('select * from public.announcement_readers(%L)', pg_temp.v('a')),
  'not_allowed', 'a reader does not see who else read');

select public.acknowledge_announcement(pg_temp.v('a'));
select public.acknowledge_announcement(pg_temp.v('a'));
select pg_temp.check(
  (select count(*) from public.unread_announcements(pg_temp.v('ws')) where id = pg_temp.v('a')) = 0,
  'confirming it takes it off the chats');
select pg_temp.check(
  (select needs_ack and read_by_me and acked_by_me
   from public.announcements_for(pg_temp.v('ws'), pg_temp.v('p')) where id = pg_temp.v('a')),
  'the list shows it is confirmed');

-- Tamer confirms straight from the chat list.
select pg_temp.login(964);
select public.acknowledge_announcement(pg_temp.v('a'));

-- Sara isn't in the project.
select pg_temp.login(963);
select pg_temp.fails(format('select public.acknowledge_announcement(%L)', pg_temp.v('a')),
  'not_allowed', 'someone outside the project cannot confirm it');

-- Hala sees who read and confirmed.
select pg_temp.login(961);
select pg_temp.check(
  (select read_count = 2 and ack_count = 2 and audience = 2
   from public.announcements_for(pg_temp.v('ws'), pg_temp.v('p')) where id = pg_temp.v('a')),
  'the author sees how many read and confirmed');
select pg_temp.check(
  (select count(*) from public.announcement_readers(pg_temp.v('a'))
   where acknowledged_at is not null and read_at is not null) = 2,
  'and who, with times');
select pg_temp.check(
  (select count(*) from public.announcement_readers(pg_temp.v('plain'))
   where read_at is null and full_name = 'Tamer') = 1,
  'and who has not opened one yet');
select pg_temp.check(
  (select count(*) from public.announcement_readers(pg_temp.v('a')) where user_id = pg_temp.uid(961)) = 0,
  'the author is not listed as a reader');

reset role;
select 'all announcement confirmation tests passed';
