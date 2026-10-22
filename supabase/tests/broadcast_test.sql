-- One announcement to several workspaces: who may send it, who sees it,
-- and how it is followed.
-- Uses its own users so it does not depend on other test files.

\set ON_ERROR_STOP on

-- Users: Adel (owner of both workspaces), Nour (member of A), Rami (admin of B only).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000094', 'adel@broadcast.example.com', '{"full_name":"Adel"}'),
  ('00000000-0000-0000-0000-000000000095', 'nour@broadcast.example.com', '{"full_name":"Nour"}'),
  ('00000000-0000-0000-0000-000000000096', 'rami@broadcast.example.com', '{"full_name":"Rami"}');

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

select pg_temp.login(94);
insert into ctx values ('a', public.create_company_workspace('Broadcast Co', 'eg', 'Branch A'));
insert into ctx values ('b', public.create_workspace(
  (select company_id from public.workspaces where id = pg_temp.v('a')), 'Branch B'));
insert into public.invites (workspace_id, email, role, invited_by) values
  (pg_temp.v('a'), 'nour@broadcast.example.com', 'member', auth.uid()),
  (pg_temp.v('b'), 'rami@broadcast.example.com', 'admin', auth.uid());
select pg_temp.login(95);
select public.accept_invite((select token from public.my_invites()));
select pg_temp.login(96);
select public.accept_invite((select token from public.my_invites()));

-- 1. Only to workspaces one runs: Rami runs B only, Nour none.
select pg_temp.fails($$ select public.post_broadcast(array[pg_temp.v('a'), pg_temp.v('b')], 'Hi') $$,
  'not_allowed', 'not to a workspace one does not run');
select pg_temp.login(95);
select pg_temp.fails($$ select public.post_broadcast(array[pg_temp.v('a')], 'Hi') $$,
  'not_allowed', 'nor by a member');

-- 2. Adel sends to both.
select pg_temp.login(94);
insert into ctx values ('bc', public.post_broadcast(array[pg_temp.v('a'), pg_temp.v('b')],
  'Eid holiday starts Thursday', false, true));
select pg_temp.check(
  (select count(*) = 1 and bool_and(broadcast_id = pg_temp.v('bc') and needs_ack)
   from public.announcements_for(pg_temp.v('b'))),
  'each workspace has its copy, asking to confirm');

-- 3. Nour reads and confirms it in A.
select pg_temp.login(95);
select public.acknowledge_announcement(
  (select id from public.announcements_for(pg_temp.v('a')) where broadcast_id = pg_temp.v('bc')));

-- 4. Followed per workspace.
select pg_temp.login(94);
select pg_temp.check(
  (select array_agg(workspace_name || ':' || audience || '/' || read_count || '/' || ack_count
                    order by workspace_name)
   from public.broadcast_reach(pg_temp.v('bc'))) = array['Branch A:1/1/1', 'Branch B:1/0/0'],
  'how many read and confirmed, in each workspace');
select pg_temp.login(96);
select pg_temp.check(
  (select array_agg(workspace_name) from public.broadcast_reach(pg_temp.v('bc'))) = array['Branch B'],
  'an admin of one sees that one only');
select pg_temp.login(95);
select pg_temp.check(not exists (select 1 from public.broadcast_reach(pg_temp.v('bc'))),
  'a member sees none of it');

reset role;
