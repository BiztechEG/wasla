-- Join codes: who manages them, what someone with the code sees, joining
-- straight away or by request, seats, and renewing.
-- Uses its own users so it does not depend on other test files.

\set ON_ERROR_STOP on

-- Users: Aya (owner), Ziad (member), Mai, Fares and Gamal (have the code).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000081', 'aya@code.example.com',   '{"full_name":"Aya"}'),
  ('00000000-0000-0000-0000-000000000082', 'ziad@code.example.com',  '{"full_name":"Ziad"}'),
  ('00000000-0000-0000-0000-000000000083', 'mai@code.example.com',   '{"full_name":"Mai"}'),
  ('00000000-0000-0000-0000-000000000084', 'fares@code.example.com', '{"full_name":"Fares"}'),
  ('00000000-0000-0000-0000-000000000085', 'gamal@code.example.com', '{"full_name":"Gamal"}');

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

create function pg_temp.ws() returns uuid language sql as $$ select v::uuid from ctx where k = 'ws' $$;
create function pg_temp.code() returns text language sql as $$ select v from ctx where k = 'code' $$;

-- 1. Aya sets up a private (not discoverable) workspace with Ziad in it.
select pg_temp.login(81);
insert into ctx values ('ws', public.create_company_workspace('Code Co', 'eg', 'Code Desk'));
insert into public.invites (workspace_id, email, role, invited_by)
values (pg_temp.ws(), 'ziad@code.example.com', 'member', auth.uid());
select pg_temp.login(82);
select public.accept_invite((select token from public.my_invites()));

-- 2. Only admins manage the code.
select pg_temp.fails($$ select * from public.set_join_code(pg_temp.ws(), true) $$, 'not_allowed',
  'a member cannot turn the code on');
select pg_temp.fails($$ select * from public.join_code(pg_temp.ws()) $$, 'not_allowed',
  'or see it');
select pg_temp.fails($$ select * from public.workspace_join_codes $$, '42501',
  'nor read the table');

select pg_temp.login(81);
select pg_temp.check(not exists (select 1 from public.join_code(pg_temp.ws())),
  'a workspace has no code until an admin turns it on');
insert into ctx select 'code', code from public.set_join_code(pg_temp.ws(), true);
select pg_temp.check(pg_temp.code() ~ '^[A-HJ-NP-Z2-9]{8}$', 'the code is eight easy characters');
select pg_temp.check(
  (select code = pg_temp.code() and not auto_join from public.join_code(pg_temp.ws())),
  'the admin sees it, joining by request by default');

-- 3. Mai, with the code typed loosely, sees where it leads and asks to join.
select pg_temp.login(83);
select pg_temp.check(
  (select workspace_name = 'Code Desk' and company_name = 'Code Co' and not auto_join
          and not member and not requested
   from public.workspace_by_code(lower(substr(pg_temp.code(), 1, 4)) || '-'
                                 || substr(pg_temp.code(), 5))),
  'someone with the code sees the workspace, whatever the case and dashes');
select pg_temp.check(not exists (select 1 from public.workspace_by_code('ZZZZZZZZ')),
  'a wrong code shows nothing');
select pg_temp.fails($$ select public.join_with_code('ZZZZZZZZ') $$, 'code_invalid',
  'and joins nothing');
select pg_temp.check(public.join_with_code(pg_temp.code(), 'Sales team') = 'requested',
  'without auto-join the code sends a request');
select pg_temp.check(public.join_with_code(pg_temp.code()) = 'requested',
  'asking twice keeps one request');
select pg_temp.check((select count(*) from public.my_join_requests()) = 1, 'just one');
select pg_temp.check(not public.is_workspace_member(pg_temp.ws()), 'not in yet');

select pg_temp.login(81);
select pg_temp.check(
  exists (select 1 from public.my_notifications()
          where kind = 'join_request' and actor_name = 'Mai' and detail = 'Sales team'),
  'the admins hear of the request, even in a workspace nobody can search');

-- 4. With auto-join on, Fares is in at once and the admins are told.
select * from public.set_join_code(pg_temp.ws(), true, true);
select pg_temp.check((select code from public.join_code(pg_temp.ws())) = pg_temp.code(),
  'changing auto-join keeps the code');
select pg_temp.login(84);
select pg_temp.check(public.join_with_code(pg_temp.code()) = 'joined', 'auto-join lets people in');
select pg_temp.check(public.is_workspace_member(pg_temp.ws()), 'Fares is a member');
select pg_temp.check(
  (select role = 'member' from public.workspace_members
   where workspace_id = pg_temp.ws() and user_id = auth.uid()),
  'as a plain member');
select pg_temp.fails($$ select public.join_with_code(pg_temp.code()) $$, 'already_member',
  'joining again says already a member');
select pg_temp.login(81);
select pg_temp.check(
  exists (select 1 from public.my_notifications()
          where kind = 'member_joined' and actor_name = 'Fares'),
  'the admins hear someone joined');

-- 5. Seats still count.
reset role;
insert into ctx select 'seats', max_members::text from public.plans
where id = (select plan_id from public.workspaces where id = pg_temp.ws());
update public.plans set max_members = 3
where id = (select plan_id from public.workspaces where id = pg_temp.ws());
select pg_temp.login(85);
select pg_temp.fails($$ select public.join_with_code(pg_temp.code()) $$, 'seat_limit_reached',
  'a full workspace takes nobody by code');
reset role;
update public.plans set max_members = (select v::integer from ctx where k = 'seats')
where id = (select plan_id from public.workspaces where id = pg_temp.ws());

-- 6. Renewing stops the old code; turning it off stops all.
select pg_temp.login(81);
insert into ctx select 'new', code from public.set_join_code(pg_temp.ws(), true, true, true);
select pg_temp.check((select v from ctx where k = 'new') <> pg_temp.code(), 'renewing gives a new code');
select pg_temp.login(85);
select pg_temp.fails($$ select public.join_with_code(pg_temp.code()) $$, 'code_invalid',
  'the old code stops working');
select pg_temp.login(81);
select * from public.set_join_code(pg_temp.ws(), false);
select pg_temp.login(85);
select pg_temp.check(
  not exists (select 1 from public.workspace_by_code((select v from ctx where k = 'new'))),
  'turned off, no code leads in');

reset role;
