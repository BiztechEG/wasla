-- Global search: files, tasks and announcements follow what each person can see.

\set ON_ERROR_STOP on

-- Users: Hala (owner), Omar (project member), Sara (outside the project),
-- Tamer (Omar's private-chat partner).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000951', 'hala@example.com',  '{"full_name":"Hala"}'),
  ('00000000-0000-0000-0000-000000000952', 'omar@example.com',  '{"full_name":"Omar"}'),
  ('00000000-0000-0000-0000-000000000953', 'sara@example.com',  '{"full_name":"Sara"}'),
  ('00000000-0000-0000-0000-000000000954', 'tamer@example.com', '{"full_name":"Tamer"}');

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

select pg_temp.login(951);
insert into ctx values ('ws', public.create_company_workspace('Delta', 'eg', 'Delta HQ'));
insert into public.invites (workspace_id, email, role, invited_by) values
  (pg_temp.v('ws'), 'omar@example.com', 'member', auth.uid()),
  (pg_temp.v('ws'), 'sara@example.com',  'member', auth.uid()),
  (pg_temp.v('ws'), 'tamer@example.com',  'member', auth.uid());
do $$
begin
  for n in 952..954 loop
    perform pg_temp.login(n);
    perform public.accept_invite((select token from public.my_invites() limit 1));
  end loop;
end $$;

select pg_temp.login(951);
with p as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.v('ws'), 'Dock', auth.uid()) returning id
)
insert into ctx select 'p', id::text from p;
insert into public.project_members (project_id, user_id, role) values
  (pg_temp.v('p'), pg_temp.uid(952), 'member');
insert into ctx values ('pc', public.project_conversation(pg_temp.v('p')));


create function pg_temp.hits(what text, q text) returns int language sql as $$
  select jsonb_array_length(public.search_workspace(pg_temp.v('ws'), q) -> what) $$;

-- Omar shares a project file, a task attachment and a private-chat file.
select pg_temp.login(952);
select pg_temp.upload(952, 'plan.pdf', 1000);
select public.add_project_file(pg_temp.v('p'), pg_temp.path(952, 'plan.pdf'),
  'مخطط المسئول.pdf', 'application/pdf', 1000);
insert into ctx values ('t_pub', public.create_task(pg_temp.v('p'), 'مراجعة المخطط', 'الدور الأول',
  p_visibility => 'public'));
insert into ctx values ('t_priv', public.create_task(pg_temp.v('p'), 'تقييم أداء سري', null));
select pg_temp.upload(952, 'secret.pdf', 1000);
select public.add_task_attachment(pg_temp.v('t_priv'), pg_temp.path(952, 'secret.pdf'),
  'تقييم سري.pdf', 'application/pdf', 1000);
insert into ctx values ('dm', public.open_direct(pg_temp.v('ws'), pg_temp.uid(954)));
select pg_temp.upload(952, 'dm.pdf', 1000);
select public.send_message(pg_temp.v('dm'), null, p_file_path => pg_temp.path(952, 'dm.pdf'),
  p_file_name => 'عقد خاص.pdf', p_file_size => 1000);

-- A file added from the Files tab is sent in the project chat, so it is
-- found as that message.
select pg_temp.check(
  (select count(*) from public.search_messages(pg_temp.v('ws'), 'مسؤول')) = 1
  and pg_temp.hits('files', 'مسؤول') = 0,
  'a project file is found, hamza-aware, as its chat message');
select pg_temp.check(pg_temp.hits('tasks', 'المخطط') = 1, 'a task is found by its title');
select pg_temp.check(pg_temp.hits('tasks', 'الاول') = 1, 'a task is found by its description');
select pg_temp.check(pg_temp.hits('files', 'سري') = 1, 'one''s own task attachment is found');
select pg_temp.check(pg_temp.hits('files', 'عقد') = 0, 'chat files are found as messages, not twice');
select pg_temp.check(pg_temp.hits('files', 'م') = 0, 'a one-letter search finds nothing');

select pg_temp.login(951);
select public.post_announcement(pg_temp.v('ws'), pg_temp.v('p'), 'اجتماع الموقع يوم الاحد');
select public.post_announcement(pg_temp.v('ws'), null, 'إجازة رسمية الخميس');
select pg_temp.check(pg_temp.hits('announcements', 'اجتماع') = 1, 'a project announcement is found');
select pg_temp.check(pg_temp.hits('tasks', 'سري') = 1, 'the owner finds a private task as its lead');
select pg_temp.check(pg_temp.hits('files', 'عقد') = 0, 'the owner does not find private-chat files');
select pg_temp.check(
  (select count(*) from public.search_messages(pg_temp.v('ws'), 'عقد')) = 0,
  'the owner does not find private-chat messages');

-- Sara is in the workspace but not the project.
select pg_temp.login(953);
select pg_temp.check(pg_temp.hits('files', 'مسؤول') = 0
  and (select count(*) from public.search_messages(pg_temp.v('ws'), 'مسؤول')) = 0,
  'outside the project: no project files');
select pg_temp.check(pg_temp.hits('tasks', 'المخطط') = 0, 'outside the project: no tasks');
select pg_temp.check(pg_temp.hits('announcements', 'اجتماع') = 0,
  'outside the project: no project announcements');
select pg_temp.check(pg_temp.hits('announcements', 'اجازه') = 1,
  'workspace announcements reach everyone, hamza-aware');

-- Tamer is in the project too, but the private task isn't his.
select pg_temp.login(951);
insert into public.project_members (project_id, user_id, role) values
  (pg_temp.v('p'), pg_temp.uid(954), 'member');
select pg_temp.login(954);
select pg_temp.check(pg_temp.hits('tasks', 'المخطط') = 1, 'a public task is found by the project');
select pg_temp.check(pg_temp.hits('tasks', 'سري') = 0, 'someone else''s private task is not found');
select pg_temp.check(pg_temp.hits('files', 'سري') = 0, 'nor its attachment');
select pg_temp.check(
  (select count(*) from public.search_messages(pg_temp.v('ws'), 'عقد')) = 1,
  'the other person in a private chat finds its file');

-- Someone outside the workspace gets nothing.
reset role;
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000955', 'x@example.com', '{"full_name":"X"}');
select pg_temp.login(955);
select pg_temp.check(public.search_workspace(pg_temp.v('ws'), 'مخطط') -> 'files' = '[]'::jsonb,
  'outside the workspace: nothing');

reset role;
select 'all search tests passed';
