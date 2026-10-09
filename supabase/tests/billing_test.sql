-- Phase 4: plans, exchange rates, plan requests, invoices and paid time.

\set ON_ERROR_STOP on

-- Users: Nour (owns the company Nile Build, in Egypt), Tarek (an admin of its
-- workspace), Salma (runs Wasla: a platform admin), Ziad (owns Gulf Co, in
-- Saudi Arabia), Mai (a member of Nile Build).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000701', 'nour@example.com',  '{"full_name":"Nour"}'),
  ('00000000-0000-0000-0000-000000000702', 'tarek@example.com', '{"full_name":"Tarek"}'),
  ('00000000-0000-0000-0000-000000000703', 'salma@example.com', '{"full_name":"Salma"}'),
  ('00000000-0000-0000-0000-000000000704', 'ziad@example.com',  '{"full_name":"Ziad"}'),
  ('00000000-0000-0000-0000-000000000705', 'mai@example.com',   '{"full_name":"Mai"}');

create temp table ctx (k text primary key, v text);
grant all on ctx to authenticated;

create function pg_temp.login(n int) returns void language sql as $$
  select set_config('role', 'authenticated', false),
         set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000' || n, false);
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

create function pg_temp.v(key text) returns uuid language sql as $$
  select v::uuid from ctx where k = key $$;
create function pg_temp.uid(n int) returns uuid language sql as $$
  select ('00000000-0000-0000-0000-000000000' || n)::uuid $$;

-- Read as the server, whoever is logged in.
create function pg_temp.notes(n int, what text) returns bigint language sql security definer as $$
  select count(*) from public.notifications where user_id = pg_temp.uid(n) and kind = what $$;
create function pg_temp.plan_of(ws text) returns text language sql security definer as $$
  select plan_id from public.workspaces where id = pg_temp.v(ws) $$;
create function pg_temp.until_of(ws text) returns timestamptz language sql security definer as $$
  select paid_until from public.workspaces where id = pg_temp.v(ws) $$;
create function pg_temp.request_status(ws text) returns text language sql security definer as $$
  select string_agg(status, ',' order by created_at) from public.plan_requests
  where workspace_id = pg_temp.v(ws) $$;
create function pg_temp.invoice(key text) returns jsonb language sql security definer as $$
  select public.invoice_json(pg_temp.v(key)) $$;

-- Nile Build has two workspaces; Gulf Co one.
select pg_temp.login(701);
insert into ctx values ('hq', public.create_company_workspace('Nile Build', 'eg', 'HQ'));
insert into ctx select 'co', company_id::text from public.workspaces where id = pg_temp.v('hq');
insert into ctx values ('site', public.create_workspace(pg_temp.v('co'), 'Site'));
insert into public.invites (workspace_id, email, role, invited_by) values
  (pg_temp.v('hq'), 'tarek@example.com', 'admin', auth.uid()),
  (pg_temp.v('hq'), 'mai@example.com', 'member', auth.uid());
select pg_temp.login(702);
select public.accept_invite((select token from public.my_invites() limit 1));
select pg_temp.login(705);
select public.accept_invite((select token from public.my_invites() limit 1));
select pg_temp.login(704);
insert into ctx values ('gulf', public.create_company_workspace('Gulf Co', 'SA', 'Riyadh'));
insert into ctx select 'gco', company_id::text from public.workspaces where id = pg_temp.v('gulf');

select pg_temp.as_server();
insert into public.platform_admins (user_id) values (pg_temp.uid(703));

-- 1. Only platform admins run the platform.
select pg_temp.login(701);
select pg_temp.check(not public.is_platform_admin(), 'a company owner is not a platform admin');
select pg_temp.fails($$ select public.admin_overview() $$, 'not_allowed',
  'and cannot see the platform''s figures');
select pg_temp.fails($$ select public.admin_set_rate('EG', 1) $$, 'not_allowed', 'nor set a rate');
select pg_temp.fails($$ select public.admin_update_plan('basic', 'Basic', 50, 50, 0.01, true) $$,
  'not_allowed', 'nor a price');
select pg_temp.fails($$ select public.admin_set_workspace_plan(pg_temp.v('hq'), 'enterprise', null) $$,
  'not_allowed', 'nor give themselves a plan');
select pg_temp.fails($$ select * from public.admin_plans() $$, 'not_allowed',
  'nor list the plans with their use');
select pg_temp.fails($$ select public.admin_billing_settings() $$, 'not_allowed',
  'nor read the payment settings as an admin');
select pg_temp.fails($$ select * from public.invoices $$, '42501', 'nor read invoices directly');
select pg_temp.fails($$ select * from public.platform_admins $$, '42501', 'nor see who the admins are');
select pg_temp.fails($$ update public.workspaces set plan_id = 'business' where id = pg_temp.v('hq') $$,
  '42501', 'nor change their plan directly');
select pg_temp.check((select count(*) from public.billing_countries) = 7,
  'everyone signed in sees the countries the platform bills');

select pg_temp.login(703);
select pg_temp.check(public.is_platform_admin(), 'a platform admin is one');

-- 2. Prices and rates.
select public.admin_update_plan('basic', 'Basic', 50, 50, 20, true);
select public.admin_update_plan('business', 'Business', 250, 500, 60, true);
select pg_temp.fails($$ select public.admin_update_plan('free', 'Free', 10, 5, 5, true) $$,
  'invalid_price', 'the free plan stays free');
select pg_temp.fails($$ select public.admin_update_plan('basic', 'Basic', 0, 50, 20, true) $$,
  '23514', 'a plan has at least one seat');

select pg_temp.login(701);
select pg_temp.check(
  public.billing_overview(pg_temp.v('co')) #>> '{company,currency}' = 'USD',
  'with no rate for the country, prices are in dollars');
select pg_temp.login(703);
select public.admin_set_rate('eg', 50);
select pg_temp.fails($$ select public.admin_set_rate('US', 1) $$, 'invalid_country',
  'rates are only for countries the platform bills');
select pg_temp.fails($$ select public.admin_set_rate('SA', 0) $$, 'invalid_rate', 'a rate is positive');
select pg_temp.login(701);
select pg_temp.check(
  (select (p ->> 'price_local')::numeric from jsonb_array_elements(
     public.billing_overview(pg_temp.v('co')) -> 'plans') p where p ->> 'id' = 'basic') = 1000
  and public.billing_overview(pg_temp.v('co')) #>> '{company,currency}' = 'EGP',
  'an Egyptian company sees prices in pounds at the rate');
select pg_temp.check(
  (select (w ->> 'members')::int from jsonb_array_elements(
     public.billing_overview(pg_temp.v('co')) -> 'workspaces') w where w ->> 'name' = 'HQ') = 3,
  'and how many people each workspace has');

-- 3. Who sees a company's billing.
select pg_temp.login(702);
select pg_temp.fails($$ select public.billing_overview(pg_temp.v('co')) $$, 'not_allowed',
  'a workspace admin who doesn''t own the company does not');
select pg_temp.check(not exists (select 1 from public.my_billing_companies()),
  'and has no company to pay for');
select pg_temp.login(704);
select pg_temp.fails($$ select public.billing_overview(pg_temp.v('co')) $$, 'not_allowed',
  'nor does another company''s owner');
select pg_temp.login(703);
select pg_temp.check(public.billing_overview(pg_temp.v('co')) ->> 'company' is not null,
  'a platform admin does');

-- 4. Asking for a plan.
select pg_temp.login(701);
insert into ctx values ('r1', public.request_plan(pg_temp.v('hq'), 'basic', 1, 'Starting the pilot'));
select public.request_plan(pg_temp.v('hq'), 'basic', 3);
select pg_temp.check(pg_temp.request_status('hq') = 'pending',
  'asking again changes the pending request rather than adding one');
select pg_temp.fails($$ select public.request_plan(pg_temp.v('hq'), 'free', 1) $$, 'invalid_plan',
  'the free plan isn''t asked for');
select pg_temp.fails($$ select public.request_plan(pg_temp.v('hq'), 'basic', 2) $$, 'invalid_plan',
  'nor odd lengths');
select pg_temp.login(702);
select pg_temp.fails($$ select public.request_plan(pg_temp.v('hq'), 'business', 1) $$, 'not_allowed',
  'only the company''s owner asks for a plan');
select pg_temp.fails($$ select public.cancel_plan_request(pg_temp.v('r1')) $$, 'not_allowed',
  'or cancels one');
select pg_temp.login(703);
select pg_temp.check(pg_temp.notes(703, 'plan_request') >= 1
  and exists (select 1 from public.my_notifications() where kind = 'plan_request'),
  'platform admins hear of it');
select pg_temp.check(
  (select plan_id || '/' || months from public.admin_requests() where workspace_id = pg_temp.v('hq'))
    = 'basic/3',
  'and see what was asked');

-- 5. An invoice for both workspaces, three months, 10% off.
select pg_temp.fails($$ select public.admin_create_invoice(pg_temp.v('co'),
    jsonb_build_array(jsonb_build_object('workspace_id', pg_temp.v('gulf'), 'plan_id', 'basic')), 3) $$,
  'invalid_items', 'an invoice only covers the company''s own workspaces');
select pg_temp.fails($$ select public.admin_create_invoice(pg_temp.v('co'),
    jsonb_build_array(jsonb_build_object('workspace_id', pg_temp.v('hq'), 'plan_id', 'basic'),
                      jsonb_build_object('workspace_id', pg_temp.v('hq'), 'plan_id', 'business')), 3) $$,
  'invalid_items', 'each workspace once');
select pg_temp.fails($$ select public.admin_create_invoice(pg_temp.v('co'),
    jsonb_build_array(jsonb_build_object('workspace_id', pg_temp.v('hq'), 'plan_id', 'free')), 3) $$,
  'invalid_plan', 'and never the free plan');
select pg_temp.fails($$ select public.admin_create_invoice(pg_temp.v('co'),
    jsonb_build_array(jsonb_build_object('workspace_id', pg_temp.v('hq'), 'plan_id', 'enterprise')), 3) $$,
  'invalid_price', 'a plan without a price needs one on the line');
insert into ctx values ('i1', public.admin_create_invoice(pg_temp.v('co'),
  jsonb_build_array(jsonb_build_object('workspace_id', pg_temp.v('hq'), 'plan_id', 'basic'),
                    jsonb_build_object('workspace_id', pg_temp.v('site'), 'plan_id', 'business')),
  3, 10, 'First quarter'));
select pg_temp.check(
  (pg_temp.invoice('i1') ->> 'subtotal_usd')::numeric = 240
  and (pg_temp.invoice('i1') ->> 'total_usd')::numeric = 216
  and (pg_temp.invoice('i1') ->> 'total_local')::numeric = 10800
  and pg_temp.invoice('i1') ->> 'currency' = 'EGP'
  and pg_temp.invoice('i1') ->> 'number' like 'WSL-____-0000_',
  'the invoice adds up the months, takes off the discount and converts at the rate');
select pg_temp.check(
  (select (l ->> 'amount_local')::numeric from jsonb_array_elements(pg_temp.invoice('i1') -> 'lines') l
   where l ->> 'workspace_name' = 'Site') = 9000
  and (select (l ->> 'members')::int from jsonb_array_elements(pg_temp.invoice('i1') -> 'lines') l
       where l ->> 'workspace_name' = 'HQ') = 3,
  'with a line per workspace');
select pg_temp.check(pg_temp.request_status('hq') = 'invoiced', 'the request is now invoiced');
select pg_temp.check(pg_temp.plan_of('hq') = 'free', 'nothing changes until it is paid');

select pg_temp.login(701);
select pg_temp.check(pg_temp.notes(701, 'invoice') = 1, 'the owner is told about the invoice');
select pg_temp.check(
  jsonb_array_length(public.billing_overview(pg_temp.v('co')) -> 'invoices') = 1,
  'and sees it');
select pg_temp.login(704);
select pg_temp.check(pg_temp.notes(704, 'invoice') = 0, 'another company''s owner hears nothing');

-- 6. Paying.
select pg_temp.login(703);
select public.admin_set_rate('EG', 55);
select pg_temp.check((pg_temp.invoice('i1') ->> 'rate')::numeric = 50,
  'a new rate leaves issued invoices as they were');
select public.admin_mark_invoice_paid(pg_temp.v('i1'), 'Bank transfer 4471');
select pg_temp.check(pg_temp.plan_of('hq') = 'basic' and pg_temp.plan_of('site') = 'business'
  and pg_temp.until_of('hq') between now() + interval '3 months' - interval '1 minute'
                                 and now() + interval '3 months' + interval '1 minute',
  'paying puts each workspace on its plan for the months paid');
select pg_temp.check(pg_temp.notes(701, 'plan_active') = 2, 'and the owner is told');
select pg_temp.fails($$ select public.admin_mark_invoice_paid(pg_temp.v('i1')) $$, 'invalid_status',
  'an invoice is paid once');
select pg_temp.fails($$ select public.admin_void_invoice(pg_temp.v('i1')) $$, 'invalid_status',
  'and a paid one can''t be voided');
select pg_temp.login(701);
select pg_temp.check(
  (select w ->> 'plan_id' from jsonb_array_elements(public.billing_overview(pg_temp.v('co')) -> 'workspaces') w
   where w ->> 'name' = 'HQ') = 'basic'
  and (select (w ->> 'max_members')::int from jsonb_array_elements(
         public.billing_overview(pg_temp.v('co')) -> 'workspaces') w where w ->> 'name' = 'HQ') = 50,
  'the owner sees the new plan and its seats');

-- 7. Renewing the same plan adds to the time paid.
select pg_temp.login(703);
insert into ctx select 'hq_until', pg_temp.until_of('hq')::text;
insert into ctx values ('i2', public.admin_create_invoice(pg_temp.v('co'),
  jsonb_build_array(jsonb_build_object('workspace_id', pg_temp.v('hq'), 'plan_id', 'basic')), 1));
select public.admin_mark_invoice_paid(pg_temp.v('i2'));
select pg_temp.check(
  pg_temp.until_of('hq') = (select v::timestamptz from ctx where k = 'hq_until') + interval '1 month',
  'renewing a plan adds the months to the time already paid');
select pg_temp.check((pg_temp.invoice('i2') ->> 'rate')::numeric = 55, 'at the rate of the day');

-- 8. A voided invoice puts the request back.
select pg_temp.login(701);
select public.request_plan(pg_temp.v('site'), 'basic', 12);
select pg_temp.login(703);
insert into ctx values ('i3', public.admin_create_invoice(pg_temp.v('co'),
  jsonb_build_array(jsonb_build_object('workspace_id', pg_temp.v('site'), 'plan_id', 'basic')), 12));
select pg_temp.check(pg_temp.request_status('site') = 'invoiced', 'the site''s request is invoiced');
select public.admin_void_invoice(pg_temp.v('i3'));
select pg_temp.check(pg_temp.request_status('site') = 'pending', 'voiding it puts the request back');
select pg_temp.login(701);
select pg_temp.check(
  jsonb_array_length(public.billing_overview(pg_temp.v('co')) -> 'invoices') = 2,
  'and the owner no longer sees it');
select public.cancel_plan_request(
  (select (w #>> '{request,id}')::uuid from jsonb_array_elements(
     public.billing_overview(pg_temp.v('co')) -> 'workspaces') w where w ->> 'name' = 'Site'));
select pg_temp.check(pg_temp.request_status('site') = 'cancelled', 'the owner can cancel a request');

-- 9. A plan given by hand, without an end, never runs out.
select pg_temp.login(703);
select public.admin_set_workspace_plan(pg_temp.v('gulf'), 'enterprise', null);
select pg_temp.fails($$ select public.admin_set_workspace_plan(pg_temp.v('gulf'), 'basic', now() - interval '1 day') $$,
  'invalid_date', 'a plan given by hand ends in the future, if at all');
select pg_temp.check(pg_temp.notes(704, 'plan_active') = 1, 'its owner is told');

-- 10. Every day: a warning a week before paid time ends, and back to free a
-- week after it ended.
select pg_temp.as_server();
update public.workspaces set paid_until = now() + interval '3 days' where id = pg_temp.v('site');
update public.workspaces set paid_until = now() - interval '8 days' where id = pg_temp.v('hq');
select pg_temp.check(public.process_subscriptions() = 2, 'the daily check finds both');
select pg_temp.check(pg_temp.plan_of('hq') = 'free' and pg_temp.until_of('hq') is null,
  'a workspace a week past its paid time goes back to the free plan');
select pg_temp.check(pg_temp.plan_of('site') = 'business', 'one still in its paid time keeps its plan');
select pg_temp.check(pg_temp.notes(701, 'plan_expired') = 1 and pg_temp.notes(701, 'plan_ending') = 1,
  'the owner is told of both');
select pg_temp.check(public.process_subscriptions() = 0, 'and only once');
select pg_temp.check(pg_temp.plan_of('gulf') = 'enterprise', 'a plan without an end stays');
select pg_temp.check(
  (select count(*) from public.plan_changes where workspace_id = pg_temp.v('hq')) = 3,
  'every plan change is recorded');

-- 11. The platform's figures.
select pg_temp.login(703);
select pg_temp.check(
  (public.admin_overview() ->> 'companies')::int >= 2
  and (public.admin_overview() ->> 'paid_usd_30d')::numeric >= 236,
  'platform admins see companies and money received');
select pg_temp.check(
  (select count(*) from public.admin_companies('nile')) = 1
  and (select owner_email from public.admin_companies('HQ')) = 'nour@example.com',
  'and find a company by its name, a workspace''s name or the owner''s email');
select pg_temp.check(
  (select rate from public.admin_rates() where country_code = 'EG') = 55,
  'and the current rate of each country');
select pg_temp.check(
  jsonb_array_length(public.admin_invoices('void')) = 1
  and public.admin_invoices('paid') -> 0 ->> 'status' = 'paid'
  and jsonb_array_length(public.admin_invoices()) >= 3,
  'and list invoices, all or by status');
select pg_temp.check(
  (select price_usd from public.admin_plans() where id = 'business') = 60
  and (select workspaces from public.admin_plans() where id = 'enterprise') >= 1
  and (select count(*) from public.admin_plans()) = 4,
  'and every plan with its price and how many workspaces are on it');
select public.admin_update_billing_settings(' Bank transfer to account 123 ', '+20 100', 'pay@example.com');
select pg_temp.check(
  public.admin_billing_settings() ->> 'instructions' = 'Bank transfer to account 123'
  and public.admin_billing_settings() ->> 'email' = 'pay@example.com',
  'and edit how companies pay');
select pg_temp.login(701);
select pg_temp.check(
  public.billing_overview(pg_temp.v('co')) #>> '{payment,phone}' = '+20 100',
  'which owners see with their bills');

-- 12. Owners can't flood the platform admins with requests.
select pg_temp.login(701);
select pg_temp.fails($$
  do $do$ begin
    for i in 1..12 loop
      perform public.cancel_plan_request(public.request_plan(pg_temp.v('site'), 'basic', 1));
    end loop;
  end $do$ $$,
  'too_many_requests', 'plan requests are limited per day');

-- 13. The website lists the offered plans with their prices, signed in or not.
reset role;
update public.plans set offered = false where id = 'enterprise';
set role anon;
select pg_temp.check(
  jsonb_array_length(public.public_plans()) = 3
  and public.public_plans() -> 0 ->> 'id' = 'free'
  and (public.public_plans() -> 2 ->> 'price_usd')::numeric = 60
  and public.public_plans() -> 0 ? 'max_members'
  and not public.public_plans() -> 0 ? 'offered',
  'visitors see the offered plans in order, with limits and prices');
reset role;
update public.plans set offered = true where id = 'enterprise';

reset role;
select 'all billing tests passed';
