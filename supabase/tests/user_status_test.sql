-- Presence: one sets one's status; coworkers see it until it runs out,
-- and nobody outside the workspace does.
-- Uses its own users so it does not depend on other test files.

\set ON_ERROR_STOP on

-- Users: Rania (owner), Omar (member), Hany (another company).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000073', 'rania@status.example.com', '{"full_name":"Rania"}'),
  ('00000000-0000-0000-0000-000000000074', 'omar@status.example.com',  '{"full_name":"Omar"}'),
  ('00000000-0000-0000-0000-000000000075', 'hany@status.example.com',  '{"full_name":"Hany"}');

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

select pg_temp.login(73);
insert into ctx values ('ws', public.create_company_workspace('Status Co', 'eg', 'Status Desk'));
insert into public.invites (workspace_id, email, role, invited_by)
values (pg_temp.v('ws'), 'omar@status.example.com', 'member', auth.uid());
select pg_temp.login(74);
select public.accept_invite((select token from public.my_invites()));

-- Omar goes on leave for a week.
select pg_temp.fails($$ select public.set_my_status('away', null, null) $$, 'invalid_status',
  'only known statuses');
select pg_temp.fails($$ select public.set_my_status('leave', null, now() - interval '1 day') $$,
  'invalid_date', 'not until a time already past');
select public.set_my_status('leave', '  Ask Rania for anything urgent  ', now() + interval '7 days');

select pg_temp.login(73);
select pg_temp.check(
  (select kind = 'leave' and note = 'Ask Rania for anything urgent' and until > now()
   from public.workspace_statuses(pg_temp.v('ws'))
   where user_id = '00000000-0000-0000-0000-000000000074'),
  'a coworker sees the status and its note');

select pg_temp.login(75);
select pg_temp.check(not exists (select 1 from public.workspace_statuses(pg_temp.v('ws'))),
  'someone outside the workspace sees nothing');
select pg_temp.fails($$ select * from public.user_status $$, '42501', 'nor the table');

-- It runs out, or is cleared.
reset role;
update public.user_status set until = now() - interval '1 minute';
select pg_temp.login(73);
select pg_temp.check(not exists (select 1 from public.workspace_statuses(pg_temp.v('ws'))),
  'a status past its time is over');
select pg_temp.login(74);
select public.set_my_status('meeting', null, null);
select public.set_my_status(null, null, null);
select pg_temp.login(73);
select pg_temp.check(not exists (select 1 from public.workspace_statuses(pg_temp.v('ws'))),
  'a cleared status is gone');

reset role;
