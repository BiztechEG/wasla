-- The management overview: who sees which workspaces, and that it counts
-- right without reaching into private chats.
-- Uses its own users so it does not depend on other test files.

\set ON_ERROR_STOP on

-- Users: Wael (company owner), Rasha (admin of Site A), Tamer (member).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000091', 'wael@mgmt.example.com',  '{"full_name":"Wael"}'),
  ('00000000-0000-0000-0000-000000000092', 'rasha@mgmt.example.com', '{"full_name":"Rasha"}'),
  ('00000000-0000-0000-0000-000000000093', 'tamer@mgmt.example.com', '{"full_name":"Tamer"}');

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

create function pg_temp.v(key text) returns uuid language sql as $$
  select v::uuid from ctx where k = key $$;
create function pg_temp.uid(n int) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-0000000000' || n)::uuid $$;
create function pg_temp.site(name text) returns jsonb language sql as $$
  select e from jsonb_array_elements(public.management_overview()) e
  where e ->> 'workspace_name' = name $$;

-- 1. Wael's company has two workspaces; Rasha runs Site A, Tamer works there.
select pg_temp.login(91);
insert into ctx values ('a', public.create_company_workspace('Mgmt Co', 'eg', 'Site A'));
insert into ctx values ('b', public.create_workspace(
  (select company_id from public.workspaces where id = pg_temp.v('a')), 'Site B'));
insert into public.invites (workspace_id, email, role, invited_by) values
  (pg_temp.v('a'), 'rasha@mgmt.example.com', 'admin', auth.uid()),
  (pg_temp.v('a'), 'tamer@mgmt.example.com', 'member', auth.uid());
select pg_temp.login(92);
select public.accept_invite((select token from public.my_invites()));
select pg_temp.login(93);
select public.accept_invite((select token from public.my_invites()));

select pg_temp.login(91);
with created as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.v('a'), 'Tower', auth.uid()) returning id
) insert into ctx select 'p', id::text from created;
insert into public.project_members (project_id, user_id)
values (pg_temp.v('p'), pg_temp.uid(93));

-- Five tasks: two open (one late), one in review, one done this week, one
-- done the week before.
insert into ctx values ('t1', public.create_task(pg_temp.v('p'), 'Open'));
insert into ctx values ('t2', public.create_task(pg_temp.v('p'), 'Late'));
insert into ctx values ('t3', public.create_task(pg_temp.v('p'), 'Review'));
insert into ctx values ('t4', public.create_task(pg_temp.v('p'), 'Done now'));
insert into ctx values ('t5', public.create_task(pg_temp.v('p'), 'Done before'));
reset role;
update public.tasks set due_at = now() - interval '1 day' where id = pg_temp.v('t2');
update public.tasks set status = 'review' where id = pg_temp.v('t3');
update public.tasks set status = 'done', done_at = now() - interval '1 day' where id = pg_temp.v('t4');
update public.tasks set status = 'done', done_at = now() - interval '9 days' where id = pg_temp.v('t5');

-- Three project messages from two people, and a private chat that must not count.
insert into ctx select 'pc', id::text from public.conversations where project_id = pg_temp.v('p');
select pg_temp.login(91);
select public.send_message(pg_temp.v('pc'), 'Hello');
select pg_temp.login(93);
select public.send_message(pg_temp.v('pc'), 'Hi');
select public.send_message(pg_temp.v('pc'), 'On it');
reset role;
insert into public.conversations (workspace_id, kind, user_a, user_b)
values (pg_temp.v('a'), 'direct', least(pg_temp.uid(91), pg_temp.uid(93)),
        greatest(pg_temp.uid(91), pg_temp.uid(93)))
returning id::text as dm \gset
insert into public.messages (conversation_id, workspace_id, sender_id, body)
select :'dm'::uuid, pg_temp.v('a'), pg_temp.uid(93), 'Private ' || g from generate_series(1, 5) g;

-- 2. Who sees what.
select pg_temp.login(91);
select pg_temp.check(
  (select array_agg(e ->> 'workspace_name' order by e ->> 'workspace_name')
   from jsonb_array_elements(public.management_overview()) e) = array['Site A', 'Site B'],
  'the company owner sees every workspace of the company');
select pg_temp.login(92);
select pg_temp.check(
  (select array_agg(e ->> 'workspace_name')
   from jsonb_array_elements(public.management_overview()) e) = array['Site A'],
  'an admin sees the workspace they run');
select pg_temp.login(93);
select pg_temp.check(public.management_overview() = '[]'::jsonb, 'a member sees none');

-- 3. The numbers.
select pg_temp.login(91);
select pg_temp.check(
  (select (s ->> 'members')::int = 3 and (s ->> 'projects')::int = 1
          and (s ->> 'open')::int = 3 and (s ->> 'late')::int = 1
          and (s ->> 'review')::int = 1 and (s ->> 'done_week')::int = 1
          and (s ->> 'done_week_before')::int = 1
          and s ->> 'company_name' = 'Mgmt Co'
   from pg_temp.site('Site A') s),
  'people, projects and tasks are counted');
select pg_temp.check(
  (select (s ->> 'messages_week')::int = 3 and (s ->> 'active_people_week')::int = 2
   from pg_temp.site('Site A') s),
  'project chat activity is counted, private chats are not');
select pg_temp.check(
  (select p ->> 'name' = 'Tower' and (p ->> 'total')::int = 5 and (p ->> 'open')::int = 3
          and (p ->> 'late')::int = 1 and (p ->> 'done')::int = 2
   from pg_temp.site('Site A') s, jsonb_array_elements(s -> 'project_list') p),
  'each project has its tasks');
select pg_temp.check(
  (select s -> 'attendance' = 'null'::jsonb from pg_temp.site('Site A') s),
  'no attendance while it is off');
select pg_temp.check(
  (select (s ->> 'open')::int = 0 and jsonb_array_length(s -> 'project_list') = 0
   from pg_temp.site('Site B') s),
  'an empty workspace shows zeros');
select pg_temp.check(
  public.management_overview()::text not like '%Private%'
  and public.management_overview()::text not like '%Hello%',
  'no message text is ever in it');

reset role;
