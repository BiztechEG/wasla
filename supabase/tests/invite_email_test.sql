-- Invitation emails: what is queued, in which language, and that only the
-- email function (with the key) takes from the queue.
-- Uses its own users so it does not depend on other test files.

\set ON_ERROR_STOP on

-- Users: Nour (owner, English), Hany (has an account, Arabic).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000071', 'nour@mail.example.com', '{"full_name":"Nour"}'),
  ('00000000-0000-0000-0000-000000000072', 'hany@mail.example.com', '{"full_name":"Hany"}');
update public.profiles set locale = 'en' where id = '00000000-0000-0000-0000-000000000071';

create temp table ctx (k text primary key, v text);
grant all on ctx to authenticated;

create function pg_temp.login(n int) returns void language sql as $$
  select set_config('role', 'authenticated', false),
         set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000' || n, false);
$$;

create function pg_temp.as_server() returns void language sql as $$
  select set_config('role', 'postgres', false),
         set_config('request.jwt.claim.sub', '', false);
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

create function pg_temp.mail(addr text) returns setof public.email_outbox
language sql security definer as $$
  select * from public.email_outbox where to_email = addr order by id $$;
create function pg_temp.key() returns text language sql security definer as $$
  select key from public.push_config $$;

-- 1. Nour invites three people.
select pg_temp.login(71);
insert into ctx values ('ws', public.create_company_workspace('Nour Co', 'eg', 'Nour Ops'));
insert into public.invites (workspace_id, email, role, invited_by) values
  ((select v::uuid from ctx where k = 'ws'), 'New.Person@Mail.example.com', 'admin', auth.uid()),
  ((select v::uuid from ctx where k = 'ws'), 'hany@mail.example.com', 'member', auth.uid());
insert into public.invites (workspace_id, phone, role, invited_by)
values ((select v::uuid from ctx where k = 'ws'), '+201000000000', 'member', auth.uid());

select pg_temp.check(
  (select count(*) = 1 and bool_and(kind = 'invite' and locale = 'en'
          and data ->> 'workspace' = 'Nour Ops' and data ->> 'company' = 'Nour Co'
          and data ->> 'inviter' = 'Nour' and data ->> 'role' = 'admin'
          and data ->> 'expires_at' is not null)
   from pg_temp.mail('new.person@mail.example.com')),
  'an invitation queues one email, in the inviter''s language for someone new');
select pg_temp.check(
  (select locale from pg_temp.mail('hany@mail.example.com')) = 'ar',
  'and in their own language for someone with an account');
select pg_temp.check(
  not exists (select 1 from pg_temp.mail('+201000000000')),
  'an invitation by phone sends no email');

-- 2. Only the email function, with the key, takes from the queue.
select pg_temp.fails($$ select * from public.email_outbox $$, '42501',
  'the app cannot read the queue');
select pg_temp.fails($$ select * from public.claim_email_batch('x') $$, '42501',
  'or take from it');
select pg_temp.fails($$ select public.finish_email_batch('x', '{}') $$, '42501',
  'or mark it sent');
select pg_temp.as_server();
select pg_temp.fails($$ select * from public.claim_email_batch('wrong') $$, 'not_allowed',
  'the queue needs the key');

create temp table batch as select * from public.claim_email_batch(pg_temp.key(), 200);
select pg_temp.check(
  (select count(*) from batch where to_email in ('new.person@mail.example.com',
                                                 'hany@mail.example.com')) = 2,
  'the function takes what is waiting');
select pg_temp.check(
  not exists (select 1 from public.claim_email_batch(pg_temp.key(), 200)
              where to_email = 'hany@mail.example.com'),
  'and nobody else takes it meanwhile');
select public.finish_email_batch(pg_temp.key(),
  array(select id from batch where to_email = 'new.person@mail.example.com'));
select pg_temp.check(
  (select sent_at is not null from pg_temp.mail('new.person@mail.example.com')),
  'a sent email is marked sent');

-- 3. A failed one is tried again later, three times at most.
update public.email_outbox set claimed_at = now() - interval '11 minutes'
where to_email = 'hany@mail.example.com';
select pg_temp.check(
  exists (select 1 from public.claim_email_batch(pg_temp.key(), 200)
          where to_email = 'hany@mail.example.com'),
  'an email that was not sent is tried again');
update public.email_outbox set claimed_at = now() - interval '11 minutes'
where to_email = 'hany@mail.example.com';
select count(*) from public.claim_email_batch(pg_temp.key(), 200);
update public.email_outbox set claimed_at = now() - interval '11 minutes'
where to_email = 'hany@mail.example.com';
select pg_temp.check(
  not exists (select 1 from public.claim_email_batch(pg_temp.key(), 200)
              where to_email = 'hany@mail.example.com'),
  'but not more than three times');

-- 4. Old emails are forgotten.
update public.email_outbox set created_at = now() - interval '8 days'
where to_email = 'hany@mail.example.com';
select public.push_tick();
select pg_temp.check(not exists (select 1 from pg_temp.mail('hany@mail.example.com')),
  'emails older than a week are removed');

reset role;
