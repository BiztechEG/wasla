-- The weekly report: who gets it, what it says, and turning it off.
-- Uses its own users so it does not depend on other test files.

\set ON_ERROR_STOP on

-- Users: Mostafa (owner), Heba (member).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000079', 'mostafa@weekly.example.com', '{"full_name":"Mostafa"}'),
  ('00000000-0000-0000-0000-000000000080', 'heba@weekly.example.com',    '{"full_name":"Heba"}');

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

select pg_temp.login(79);
insert into ctx values ('ws', public.create_company_workspace('Weekly Co', 'eg', 'Weekly Desk'));
insert into public.invites (workspace_id, email, role, invited_by)
values (pg_temp.v('ws'), 'heba@weekly.example.com', 'member', auth.uid());
select pg_temp.login(80);
select public.accept_invite((select token from public.my_invites()));
select pg_temp.login(79);
with created as (
  insert into public.projects (workspace_id, name, created_by)
  values (pg_temp.v('ws'), 'Weekly Project', auth.uid()) returning id
) insert into ctx select 'p', id::text from created;
insert into ctx values ('t1', public.create_task(pg_temp.v('p'), 'Done one'));
insert into ctx values ('t2', public.create_task(pg_temp.v('p'), 'Late one'));
reset role;
update public.tasks set status = 'done', done_at = now() - interval '2 days' where id = pg_temp.v('t1');
update public.tasks set due_at = now() - interval '1 day' where id = pg_temp.v('t2');
-- An empty workspace of the same owner says nothing.
select pg_temp.login(79);
select public.create_workspace((select company_id from public.workspaces where id = pg_temp.v('ws')),
                               'Weekly Empty');
reset role;
delete from public.email_outbox;
select set_config('request.jwt.claim.sub', '', false);

-- 1. The owner gets it; the member does not.
select pg_temp.check(public.send_weekly_reports() >= 1, 'reports go out');
select pg_temp.check(
  (select count(*) = 1 and bool_and((detail::jsonb ->> 'done')::int = 1
                                     and (detail::jsonb ->> 'late')::int = 1
                                     and detail::jsonb ->> 'workspace' = 'Weekly Desk')
   from public.notifications
   where user_id = pg_temp.uid(79) and kind = 'weekly_report'),
  'one report per workspace with something in it, with its numbers');
select pg_temp.check(
  not exists (select 1 from public.notifications
              where user_id = pg_temp.uid(80) and kind = 'weekly_report'),
  'a member gets none');
select pg_temp.check(
  (select count(*) = 1 and bool_and(locale = 'ar'
     and jsonb_array_length(data -> 'workspaces') = 1)
   from public.email_outbox
   where kind = 'weekly_report' and to_email = 'mostafa@weekly.example.com'),
  'and one email with every workspace');
select pg_temp.check(coalesce(current_setting('request.jwt.claim.sub', true), '') = '',
  'it leaves no one signed in');

-- 2. Turned off, nothing comes.
select pg_temp.login(79);
select pg_temp.check(public.my_weekly_report(), 'it is on at first');
select public.set_weekly_report(false);
select pg_temp.check(not public.my_weekly_report(), 'and can be turned off');
reset role;
delete from public.notifications where kind = 'weekly_report';
delete from public.email_outbox;
select public.send_weekly_reports();
select pg_temp.check(
  not exists (select 1 from public.notifications
              where user_id = pg_temp.uid(79) and kind = 'weekly_report')
  and not exists (select 1 from public.email_outbox where to_email = 'mostafa@weekly.example.com'),
  'then nothing is sent');

reset role;
