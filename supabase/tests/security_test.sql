-- Checks for the fixes in migration 3, plus guards that every function and
-- table in public stays closed to anonymous callers.

\set ON_ERROR_STOP on

-- Users: Laila (owner), Badr (co-owner, later removed), Dina (admin),
-- Fady (member), Ehab (admin who leaves), Ghada (invitee).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000201', 'laila@example.com', '{"full_name":"Laila"}'),
  ('00000000-0000-0000-0000-000000000202', 'badr@example.com',  '{"full_name":"Badr"}'),
  ('00000000-0000-0000-0000-000000000203', 'dina@example.com',  '{"full_name":"Dina"}'),
  ('00000000-0000-0000-0000-000000000204', 'fady@example.com',  '{"full_name":"Fady"}'),
  ('00000000-0000-0000-0000-000000000205', 'ehab@example.com',  '{"full_name":"Ehab"}'),
  ('00000000-0000-0000-0000-000000000206', 'ghada@example.com', '{"full_name":"Ghada"}');

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

create function pg_temp.ws() returns uuid language sql as $$ select v::uuid from ctx where k = 'ws' $$;
create function pg_temp.uid(n int) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-000000000' || n)::uuid $$;

create function pg_temp.invite(email text, r public.workspace_role) returns void language sql as $$
  insert into public.invites (workspace_id, email, role, invited_by)
  values (pg_temp.ws(), email, r, auth.uid());
$$;

create function pg_temp.accept() returns void language sql as $$
  select public.accept_invite((select token from public.my_invites() limit 1));
$$;

-- Laila sets up a discoverable workspace; Badr, Dina, Fady and Ehab join.
select pg_temp.login(201);
insert into ctx values ('ws', public.create_company_workspace('Sama', 'ae', 'Sama HQ'));
update public.workspaces set discoverable = true where id = pg_temp.ws();
select pg_temp.invite('badr@example.com', 'admin');
select pg_temp.invite('dina@example.com', 'admin');
select pg_temp.invite('fady@example.com', 'member');
select pg_temp.invite('ehab@example.com', 'admin');
select pg_temp.login(202); select pg_temp.accept();
select pg_temp.login(203); select pg_temp.accept();
select pg_temp.login(204); select pg_temp.accept();
select pg_temp.login(205); select pg_temp.accept();

-- 1. Creating a project and getting it back in one request works.
select pg_temp.login(201);
with created as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.ws(), 'Launch', auth.uid())
  returning id
)
insert into ctx select 'project', id::text from created;
select pg_temp.check((select v from ctx where k = 'project') is not null,
  'admin creates a project and reads it back');

-- 2. A removed co-owner who asks to join again comes back as a plain member,
--    without his old project roles.
update public.workspace_members set role = 'owner' where user_id = pg_temp.uid(202);
insert into public.project_members (project_id, user_id, role)
values ((select v::uuid from ctx where k = 'project'), pg_temp.uid(202), 'lead');
update public.workspace_members set status = 'inactive' where user_id = pg_temp.uid(202);
select pg_temp.check(
  not exists (select 1 from public.project_members where user_id = pg_temp.uid(202)),
  'leaving a workspace drops its project memberships');

select pg_temp.login(202);
insert into ctx values ('req', public.request_to_join(pg_temp.ws()));
select pg_temp.login(203);
select public.decide_join_request((select v::uuid from ctx where k = 'req'), true);
select pg_temp.check(
  (select role from public.workspace_members where user_id = pg_temp.uid(202)) = 'member',
  'approved returning owner comes back as a member');

-- 3. Admins cannot choose an invitation's expiry, token or status.
select pg_temp.login(205);
do $$ begin
  insert into public.invites (workspace_id, email, role, invited_by, expires_at)
  values (pg_temp.ws(), 'alt@example.com', 'admin', auth.uid(), 'infinity');
  raise exception 'FAILED: admin set an invitation expiry';
exception when insufficient_privilege then raise notice 'ok: invitation expiry is not settable';
end $$;

-- 4. An invitation stops working once its sender is no longer an admin.
select pg_temp.invite('ghada@example.com', 'admin');
select pg_temp.login(201);
update public.workspace_members set status = 'inactive' where user_id = pg_temp.uid(205);
select pg_temp.login(206);
do $$ begin
  perform pg_temp.accept();
  raise exception 'FAILED: accepted an invitation from a removed admin';
exception when raise_exception then
  if sqlerrm <> 'invite_invalid' then raise; end if;
  raise notice 'ok: invitation from a removed admin is void';
end $$;

-- 5. Accepting an invitation never lowers a current member's role.
select pg_temp.login(203);
select pg_temp.invite('laila@example.com', 'member');
select pg_temp.login(201);
select pg_temp.accept();
select pg_temp.check(public.workspace_role_of(pg_temp.ws()) = 'owner',
  'owner stays owner after accepting a member invitation');

-- 6. Search treats % and _ as text.
select pg_temp.login(206);
select pg_temp.check((select count(*) from public.search_workspaces('%%')) = 0, 'search ignores % wildcards');
select pg_temp.check((select count(*) from public.search_workspaces('__')) = 0, 'search ignores _ wildcards');
select pg_temp.check((select count(*) from public.search_workspaces('Sama')) = 1, 'search still finds by name');

-- 7. Removed people's contact details are no longer visible to members.
select pg_temp.login(204);
select pg_temp.check(not exists (select 1 from public.profiles where id = pg_temp.uid(205)),
  'member no longer sees a removed admin');

-- 8. Size limits.
select pg_temp.login(201);
do $$ begin
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.ws(), repeat('x', 101), auth.uid());
  raise exception 'FAILED: 101-character project name';
exception when check_violation then raise notice 'ok: project names are capped';
end $$;

-- 9. Join requests are rate limited per workspace.
select pg_temp.login(206);
do $$
declare r uuid;
begin
  for i in 1..5 loop
    r := public.request_to_join(pg_temp.ws());
    perform public.cancel_join_request(r);
  end loop;
  perform public.request_to_join(pg_temp.ws());
  raise exception 'FAILED: sixth join request in a day';
exception when raise_exception then
  if sqlerrm <> 'too_many_requests' then raise; end if;
  raise notice 'ok: join requests are rate limited';
end $$;

-- 10. A confirmed email change reaches the profile.
reset role;
update auth.users set email = 'fady.new@example.com' where id = pg_temp.uid(204);
select pg_temp.check(
  (select email from public.profiles where id = pg_temp.uid(204)) = 'fady.new@example.com',
  'profile email follows the account');

-- 11. Guards: nothing in public is open to anonymous callers.
select pg_temp.check(
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')),
  'anon cannot execute any public function');
select pg_temp.check(
  not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where n.nspname = 'public' and c.relkind in ('r', 'v', 'm')
                and has_table_privilege('anon', c.oid, 'select, insert, update, delete')),
  'anon has no table access');
select pg_temp.check(
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.prosecdef
                and not ('search_path=public, pg_temp' = any (coalesce(p.proconfig, '{}')))),
  'every security definer function pins its search_path');

\echo 'all security tests passed'
