-- Phase 4: subscriptions and billing.
--
-- Each workspace has a plan. Prices are in USD a month, and a company pays
-- in its country's currency at the rate a platform admin sets for that
-- country; old rates are kept, and each invoice stores the rate it used.
-- One invoice per company covers its workspaces, a line each.
--
-- Until online payment arrives, payment is by bank transfer or similar: a
-- company owner asks for a plan from the app, a platform admin issues the
-- invoice and marks it paid, and that puts each workspace on its plan for the
-- months paid. A workspace whose paid time ran out more than a week ago goes
-- back to the free plan: nobody loses access, but it takes no new members or
-- files beyond the free plan's limits.
--
-- Platform admins are the people who run Wasla itself, not a company's
-- admins. The first one is added by hand in the Supabase SQL editor:
--   insert into public.platform_admins (user_id)
--   select id from auth.users where email = '...';

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.platform_admins (
  user_id    uuid primary key references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);

-- Plans can be hidden from new requests without touching workspaces on them.
alter table public.plans
  add column offered boolean not null default true,
  add column sort    integer not null default 0;
update public.plans set sort = case id when 'free' then 0 when 'basic' then 1
                                       when 'business' then 2 else 3 end;
alter table public.plans
  add constraint plans_name_len check (length(trim(name)) between 1 and 50),
  add constraint plans_limits check ((max_members is null or max_members >= 1)
                                     and (storage_gb is null or storage_gb >= 1)
                                     and price_usd_month >= 0);

-- The currency each country pays in, and its rates over time (local units for
-- one US dollar).
create table public.billing_countries (
  country_code char(2) primary key,
  currency     char(3) not null
);

insert into public.billing_countries (country_code, currency) values
  ('EG', 'EGP'), ('SA', 'SAR'), ('AE', 'AED'), ('KW', 'KWD'),
  ('QA', 'QAR'), ('BH', 'BHD'), ('OM', 'OMR');

create table public.exchange_rates (
  id             bigint generated always as identity primary key,
  country_code   char(2) not null references public.billing_countries (country_code),
  rate           numeric(14, 4) not null check (rate > 0 and rate < 1000000),
  set_by         uuid references public.profiles (id),
  effective_from timestamptz not null default now()
);

create index exchange_rates_country_idx on public.exchange_rates (country_code, effective_from desc);

-- How to pay, shown with every invoice. One row, edited by platform admins.
create table public.billing_settings (
  id                   boolean primary key default true check (id),
  payment_instructions text not null default '' check (length(payment_instructions) <= 2000),
  support_phone        text not null default '' check (length(support_phone) <= 30),
  support_email        text not null default '' check (length(support_email) <= 254)
);
insert into public.billing_settings default values;

-- Paid time on a workspace's plan; null for the free plan, and for a plan
-- given without an end (a pilot or an enterprise agreement).
alter table public.workspaces
  add column paid_until        timestamptz,
  -- The paid_until the owner was last warned about, so they are warned once.
  add column ending_noticed_for timestamptz;

create table public.plan_requests (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  plan_id      text not null references public.plans (id),
  months       integer not null check (months in (1, 3, 6, 12)),
  note         text check (length(note) <= 500),
  status       text not null default 'pending' check (status in ('pending', 'invoiced', 'cancelled')),
  invoice_id   uuid,
  requested_by uuid not null references public.profiles (id),
  created_at   timestamptz not null default now()
);

create unique index plan_requests_one_pending on public.plan_requests (workspace_id)
  where status = 'pending';

create sequence public.invoice_numbers;

create table public.invoices (
  id           uuid primary key default gen_random_uuid(),
  number       text not null unique,
  company_id   uuid not null references public.companies (id) on delete restrict,
  status       text not null default 'issued' check (status in ('issued', 'paid', 'void')),
  months       integer not null check (months between 1 and 24),
  currency     char(3) not null,
  rate         numeric(14, 4) not null check (rate > 0),
  subtotal_usd numeric(12, 2) not null,
  discount_pct numeric(5, 2) not null default 0 check (discount_pct between 0 and 100),
  total_usd    numeric(12, 2) not null,
  total_local  numeric(14, 2) not null,
  note         text check (length(note) <= 500),
  issued_by    uuid references public.profiles (id),
  issued_at    timestamptz not null default now(),
  due_at       timestamptz not null,
  paid_at      timestamptz,
  paid_by      uuid references public.profiles (id),
  payment_ref  text check (length(payment_ref) <= 200),
  voided_at    timestamptz
);

create index invoices_company_idx on public.invoices (company_id, issued_at desc);

alter table public.plan_requests
  add constraint plan_requests_invoice_fk foreign key (invoice_id)
  references public.invoices (id) on delete set null;

-- What each workspace's line said when the invoice was issued, so later
-- renames and price changes don't rewrite it.
create table public.invoice_lines (
  id             uuid primary key default gen_random_uuid(),
  invoice_id     uuid not null references public.invoices (id) on delete cascade,
  workspace_id   uuid references public.workspaces (id) on delete set null,
  workspace_name text not null,
  plan_id        text not null references public.plans (id),
  plan_name      text not null,
  members        integer not null,
  unit_usd       numeric(10, 2) not null,
  amount_usd     numeric(12, 2) not null,
  amount_local   numeric(14, 2) not null
);

create index invoice_lines_invoice_idx on public.invoice_lines (invoice_id);

create table public.plan_changes (
  id           bigint generated always as identity primary key,
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  from_plan    text,
  to_plan      text not null,
  paid_until   timestamptz,
  reason       text not null check (reason in ('invoice', 'admin', 'expired')),
  invoice_id   uuid references public.invoices (id) on delete set null,
  actor_id     uuid references public.profiles (id),
  created_at   timestamptz not null default now()
);

create index plan_changes_workspace_idx on public.plan_changes (workspace_id, created_at desc);

-- Billing news reaches company owners, and plan requests reach platform
-- admins, through the notifications the bell already shows.
alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('assigned', 'status', 'comment', 'due_changed', 'nudge',
                  'due_soon', 'overdue', 'reminder', 'unassigned', 'deleted',
                  'plan_request', 'invoice', 'plan_active', 'plan_ending', 'plan_expired'));

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create function public.is_platform_admin()
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from platform_admins where user_id = auth.uid());
$$;

create function public.require_platform_admin()
returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_platform_admin() then
    raise exception 'not_allowed';
  end if;
end;
$$;

-- The currency a country pays in and its rate now; US dollars where the
-- country has no rate yet.
create function public.country_rate(p_country text)
returns table (currency char(3), rate numeric)
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(r.currency, 'USD')::char(3), coalesce(r.rate, 1)
  from (select 1) one
  left join lateral (
    select bc.currency, er.rate
    from billing_countries bc
    join exchange_rates er on er.country_code = bc.country_code
    where bc.country_code = upper(p_country) and er.effective_from <= now()
    order by er.effective_from desc
    limit 1
  ) r on true;
$$;

create function public.active_members(p_workspace uuid)
returns integer
language sql stable security definer set search_path = public, pg_temp as $$
  select count(*)::integer from workspace_members
  where workspace_id = p_workspace and status = 'active';
$$;

create function public.notify_billing(p_users uuid[], p_workspace uuid, p_kind text, p_detail text)
returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into notifications (user_id, workspace_id, kind, actor_id, detail)
  select distinct u, p_workspace, p_kind, auth.uid(), left(p_detail, 200)
  from unnest(p_users) u
  where u is not null and u is distinct from auth.uid();
$$;

create function public.company_owner_of(p_workspace uuid)
returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select c.owner_id from workspaces w join companies c on c.id = w.company_id
  where w.id = p_workspace;
$$;

-- Moves a workspace to a plan and records why.
create function public.put_on_plan(
  p_workspace uuid, p_plan text, p_until timestamptz, p_reason text, p_invoice uuid default null
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  previous text;
begin
  select plan_id into previous from workspaces where id = p_workspace for update;
  update workspaces
  set plan_id = p_plan,
      paid_until = case when p_plan = 'free' then null else p_until end,
      ending_noticed_for = null
  where id = p_workspace;
  insert into plan_changes (workspace_id, from_plan, to_plan, paid_until, reason, invoice_id, actor_id)
  values (p_workspace, previous, p_plan, case when p_plan = 'free' then null else p_until end,
          p_reason, p_invoice, auth.uid());
end;
$$;

-- ---------------------------------------------------------------------------
-- Company owners
-- ---------------------------------------------------------------------------

-- The companies one pays for.
create function public.my_billing_companies()
returns table (id uuid, name text, country_code char(2))
language sql stable security definer set search_path = public, pg_temp as $$
  select c.id, c.name, c.country_code from companies c
  where c.owner_id = auth.uid()
  order by c.created_at;
$$;

create function public.invoice_json(p_invoice uuid)
returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'id', i.id, 'number', i.number, 'company_id', i.company_id, 'company_name', c.name,
    'status', i.status, 'months', i.months, 'currency', i.currency, 'rate', i.rate,
    'subtotal_usd', i.subtotal_usd, 'discount_pct', i.discount_pct,
    'total_usd', i.total_usd, 'total_local', i.total_local, 'note', i.note,
    'issued_at', i.issued_at, 'due_at', i.due_at, 'paid_at', i.paid_at,
    'payment_ref', i.payment_ref,
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
               'workspace_id', l.workspace_id, 'workspace_name', l.workspace_name,
               'plan_id', l.plan_id, 'plan_name', l.plan_name, 'members', l.members,
               'unit_usd', l.unit_usd, 'amount_usd', l.amount_usd,
               'amount_local', l.amount_local) order by l.workspace_name)
      from invoice_lines l where l.invoice_id = i.id), '[]'::jsonb))
  from invoices i join companies c on c.id = i.company_id
  where i.id = p_invoice;
$$;

-- Everything the subscription screen shows for a company: its plans and
-- prices in its currency, each workspace's plan and use, open requests,
-- invoices, and how to pay.
create function public.billing_overview(p_company uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  co   companies%rowtype;
  v_currency char(3);
  v_rate     numeric;
begin
  select * into co from companies where id = p_company;
  if co.id is null or not (co.owner_id = auth.uid() or public.is_platform_admin()) then
    raise exception 'not_allowed';
  end if;
  select r.currency, r.rate into v_currency, v_rate from public.country_rate(co.country_code) r;

  return jsonb_build_object(
    'company', jsonb_build_object('id', co.id, 'name', co.name, 'country_code', co.country_code,
                                  'currency', v_currency, 'rate', v_rate),
    'plans', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'name', p.name, 'max_members', p.max_members,
               'storage_gb', p.storage_gb, 'price_usd', p.price_usd_month,
               'price_local', round(p.price_usd_month * v_rate, 2), 'offered', p.offered)
             order by p.sort, p.price_usd_month)
      from plans p), '[]'::jsonb),
    'workspaces', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', w.id, 'name', w.name, 'plan_id', w.plan_id, 'plan_name', p.name,
               'max_members', p.max_members, 'storage_gb', p.storage_gb,
               'paid_until', w.paid_until,
               'members', public.active_members(w.id),
               'storage_bytes', public.stored_bytes(w.id::text || '/'),
               'request', (select jsonb_build_object('id', r.id, 'plan_id', r.plan_id,
                                                     'months', r.months, 'status', r.status,
                                                     'created_at', r.created_at)
                           from plan_requests r
                           where r.workspace_id = w.id and r.status in ('pending', 'invoiced')
                           order by r.created_at desc limit 1))
             order by w.created_at)
      from workspaces w join plans p on p.id = w.plan_id
      where w.company_id = co.id), '[]'::jsonb),
    'invoices', coalesce((
      select jsonb_agg(public.invoice_json(i.id) order by i.issued_at desc)
      from (select id, issued_at from invoices
            where company_id = co.id and status <> 'void'
            order by issued_at desc limit 50) i), '[]'::jsonb),
    'payment', (select jsonb_build_object('instructions', s.payment_instructions,
                                          'phone', s.support_phone, 'email', s.support_email)
                from billing_settings s)
  );
end;
$$;

-- Asks the platform for a plan for one workspace. A newer ask replaces a
-- pending one.
create function public.request_plan(p_workspace uuid, p_plan text, p_months integer, p_note text default null)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me      uuid := auth.uid();
  co      uuid;
  req     uuid;
begin
  select w.company_id into co from workspaces w join companies c on c.id = w.company_id
  where w.id = p_workspace and c.owner_id = me;
  if co is null then
    raise exception 'not_allowed';
  end if;
  if not exists (select 1 from plans where id = p_plan and offered and id <> 'free') then
    raise exception 'invalid_plan';
  end if;
  if p_months is null or p_months not in (1, 3, 6, 12) then
    raise exception 'invalid_plan';
  end if;
  -- Ten asks a day is plenty; it keeps platform admins' bells usable.
  perform pg_advisory_xact_lock(hashtext('wasla_plan_requests:' || co::text));
  if (select count(*) from plan_requests r join workspaces w on w.id = r.workspace_id
      where w.company_id = co and r.created_at > now() - interval '1 day') >= 10 then
    raise exception 'too_many_requests';
  end if;
  p_note := nullif(left(trim(p_note), 500), '');

  update plan_requests set plan_id = p_plan, months = p_months, note = p_note,
                           requested_by = me, created_at = now()
  where workspace_id = p_workspace and status = 'pending'
  returning id into req;
  if req is null then
    insert into plan_requests (workspace_id, plan_id, months, note, requested_by)
    values (p_workspace, p_plan, p_months, p_note, me)
    returning id into req;
  end if;

  perform public.notify_billing(array(select user_id from platform_admins), p_workspace,
                                'plan_request', (select name from plans where id = p_plan));
  return req;
end;
$$;

create function public.cancel_plan_request(p_request uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update plan_requests r set status = 'cancelled'
  from workspaces w join companies c on c.id = w.company_id
  where r.id = p_request and r.status = 'pending'
    and w.id = r.workspace_id and c.owner_id = auth.uid();
  if not found then
    raise exception 'not_allowed';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Platform admins
-- ---------------------------------------------------------------------------

create function public.admin_overview()
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public.require_platform_admin();
  return jsonb_build_object(
    'companies', (select count(*) from companies),
    'workspaces', (select count(*) from workspaces),
    'paid_workspaces', (select count(*) from workspaces where plan_id <> 'free'),
    'members', (select count(*) from workspace_members where status = 'active'),
    'pending_requests', (select count(*) from plan_requests where status = 'pending'),
    'unpaid_invoices', (select count(*) from invoices where status = 'issued'),
    'unpaid_usd', (select coalesce(sum(total_usd), 0) from invoices where status = 'issued'),
    'paid_usd_30d', (select coalesce(sum(total_usd), 0) from invoices
                     where status = 'paid' and paid_at > now() - interval '30 days'));
end;
$$;

create function public.admin_companies(p_search text default null)
returns table (
  id uuid, name text, country_code char(2), owner_name text, owner_email text,
  created_at timestamptz, workspaces jsonb, pending_requests integer, unpaid_invoices integer
)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public.require_platform_admin();
  return query
  select c.id, c.name, c.country_code, p.full_name, p.email, c.created_at,
         coalesce((select jsonb_agg(jsonb_build_object(
                     'id', w.id, 'name', w.name, 'plan_id', w.plan_id, 'plan_name', pl.name,
                     'paid_until', w.paid_until, 'members', public.active_members(w.id))
                   order by w.created_at)
                   from workspaces w join plans pl on pl.id = w.plan_id
                   where w.company_id = c.id), '[]'::jsonb),
         (select count(*)::integer from plan_requests r join workspaces w on w.id = r.workspace_id
          where w.company_id = c.id and r.status = 'pending'),
         (select count(*)::integer from invoices i where i.company_id = c.id and i.status = 'issued')
  from companies c join profiles p on p.id = c.owner_id
  where p_search is null or length(trim(p_search)) = 0
     or c.name ilike '%' || trim(p_search) || '%'
     or p.email ilike '%' || trim(p_search) || '%'
     or exists (select 1 from workspaces w where w.company_id = c.id
                and w.name ilike '%' || trim(p_search) || '%')
  order by (select count(*) from plan_requests r join workspaces w on w.id = r.workspace_id
            where w.company_id = c.id and r.status = 'pending') > 0 desc,
           c.created_at desc
  limit 200;
end;
$$;

-- Pending plan requests, oldest first, with the plan each workspace is on.
create function public.admin_requests()
returns table (
  id uuid, company_id uuid, company_name text, workspace_id uuid, workspace_name text,
  current_plan text, plan_id text, plan_name text, months integer, note text,
  requested_by_name text, created_at timestamptz
)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public.require_platform_admin();
  return query
  select r.id, c.id, c.name, w.id, w.name, cp.name, r.plan_id, p.name, r.months, r.note,
         pr.full_name, r.created_at
  from plan_requests r
  join workspaces w on w.id = r.workspace_id
  join plans cp on cp.id = w.plan_id
  join companies c on c.id = w.company_id
  join plans p on p.id = r.plan_id
  join profiles pr on pr.id = r.requested_by
  where r.status = 'pending'
  order by r.created_at;
end;
$$;

-- The newest 200 invoices, or those with one status, as one JSON array.
create function public.admin_invoices(p_status text default null)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public.require_platform_admin();
  return coalesce((
    select jsonb_agg(public.invoice_json(i.id) order by i.issued_at desc)
    from (select id, issued_at from invoices
          where p_status is null or status = p_status
          order by issued_at desc limit 200) i), '[]'::jsonb);
end;
$$;

create function public.admin_rates()
returns table (country_code char(2), currency char(3), rate numeric, effective_from timestamptz,
               set_by_name text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public.require_platform_admin();
  return query
  select bc.country_code, bc.currency, er.rate, er.effective_from, p.full_name
  from billing_countries bc
  left join lateral (select * from exchange_rates e where e.country_code = bc.country_code
                     order by e.effective_from desc limit 1) er on true
  left join profiles p on p.id = er.set_by
  order by bc.country_code = 'EG' desc, bc.country_code;
end;
$$;

-- Every plan, with how many workspaces are on it.
create function public.admin_plans()
returns table (id text, name text, max_members integer, storage_gb integer, price_usd numeric,
               offered boolean, workspaces integer)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public.require_platform_admin();
  return query
  select p.id, p.name, p.max_members, p.storage_gb, p.price_usd_month, p.offered,
         (select count(*)::integer from workspaces w where w.plan_id = p.id)
  from plans p
  order by p.sort, p.price_usd_month;
end;
$$;

create function public.admin_billing_settings()
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public.require_platform_admin();
  return (select jsonb_build_object('instructions', s.payment_instructions,
                                    'phone', s.support_phone, 'email', s.support_email)
          from billing_settings s);
end;
$$;

create function public.admin_set_rate(p_country text, p_rate numeric)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.require_platform_admin();
  if not exists (select 1 from billing_countries where country_code = upper(p_country)) then
    raise exception 'invalid_country';
  end if;
  if p_rate is null or p_rate <= 0 or p_rate >= 1000000 then
    raise exception 'invalid_rate';
  end if;
  insert into exchange_rates (country_code, rate, set_by)
  values (upper(p_country), round(p_rate, 4), auth.uid());
end;
$$;

create function public.admin_update_plan(
  p_plan text, p_name text, p_max_members integer, p_storage_gb integer,
  p_price numeric, p_offered boolean
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.require_platform_admin();
  if p_plan = 'free' and coalesce(p_price, 0) <> 0 then
    raise exception 'invalid_price';
  end if;
  if p_price is null or p_price < 0 or p_price > 100000 then
    raise exception 'invalid_price';
  end if;
  update plans
  set name = trim(p_name), max_members = p_max_members, storage_gb = p_storage_gb,
      price_usd_month = round(p_price, 2), offered = coalesce(p_offered, offered)
  where id = p_plan;
  if not found then
    raise exception 'invalid_plan';
  end if;
end;
$$;

create function public.admin_update_billing_settings(
  p_instructions text, p_phone text, p_email text
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.require_platform_admin();
  update billing_settings
  set payment_instructions = coalesce(trim(p_instructions), ''),
      support_phone = coalesce(trim(p_phone), ''),
      support_email = coalesce(trim(p_email), '');
end;
$$;

-- An invoice for some of a company's workspaces, each on a plan, for a number
-- of months. p_items is [{"workspace_id": ..., "plan_id": ..., "price_usd": optional}];
-- a price given there replaces the plan's (an enterprise agreement).
create function public.admin_create_invoice(
  p_company  uuid,
  p_items    jsonb,
  p_months   integer,
  p_discount numeric default 0,
  p_note     text default null,
  p_due_days integer default 14
) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  co       companies%rowtype;
  v_currency char(3);
  v_rate     numeric;
  inv      uuid;
  item     jsonb;
  ws       workspaces%rowtype;
  pl       plans%rowtype;
  unit     numeric;
  subtotal numeric := 0;
  total    numeric;
  seen     uuid[] := '{}';
begin
  perform public.require_platform_admin();
  select * into co from companies where id = p_company;
  if co.id is null then
    raise exception 'not_found';
  end if;
  if p_months is null or p_months < 1 or p_months > 24 then
    raise exception 'invalid_months';
  end if;
  p_discount := coalesce(p_discount, 0);
  if p_discount < 0 or p_discount > 100 then
    raise exception 'invalid_discount';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0
     or jsonb_array_length(p_items) > 50 then
    raise exception 'invalid_items';
  end if;
  select r.currency, r.rate into v_currency, v_rate from public.country_rate(co.country_code) r;

  insert into invoices (number, company_id, months, currency, rate, subtotal_usd, discount_pct,
                        total_usd, total_local, note, issued_by, due_at)
  values ('WSL-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('invoice_numbers')::text, 5, '0'),
          co.id, p_months, v_currency, v_rate, 0, round(p_discount, 2), 0, 0,
          nullif(left(trim(p_note), 500), ''), auth.uid(),
          now() + make_interval(days => greatest(coalesce(p_due_days, 14), 0)))
  returning id into inv;

  for item in select * from jsonb_array_elements(p_items) loop
    select * into ws from workspaces
    where id = (item ->> 'workspace_id')::uuid and company_id = co.id;
    if ws.id is null or ws.id = any (seen) then
      raise exception 'invalid_items';
    end if;
    seen := seen || ws.id;
    select * into pl from plans where id = item ->> 'plan_id';
    if pl.id is null or pl.id = 'free' then
      raise exception 'invalid_plan';
    end if;
    unit := round(coalesce((item ->> 'price_usd')::numeric, pl.price_usd_month), 2);
    if unit <= 0 or unit > 100000 then
      raise exception 'invalid_price';
    end if;
    insert into invoice_lines (invoice_id, workspace_id, workspace_name, plan_id, plan_name,
                               members, unit_usd, amount_usd, amount_local)
    values (inv, ws.id, ws.name, pl.id, pl.name, public.active_members(ws.id), unit,
            unit * p_months, round(unit * p_months * v_rate, 2));
    subtotal := subtotal + unit * p_months;
  end loop;

  total := round(subtotal * (1 - p_discount / 100), 2);
  update invoices
  set subtotal_usd = subtotal, total_usd = total, total_local = round(total * v_rate, 2)
  where id = inv;

  update plan_requests set status = 'invoiced', invoice_id = inv
  where status = 'pending' and workspace_id = any (seen);

  perform public.notify_billing(array[co.owner_id], seen[1], 'invoice',
                                (select number from invoices where id = inv));
  return inv;
end;
$$;

-- Payment arrived: each workspace on the invoice goes on its plan for the
-- months paid, added to time already paid on the same plan.
create function public.admin_mark_invoice_paid(p_invoice uuid, p_reference text default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  inv   invoices%rowtype;
  line  record;
  until timestamptz;
begin
  perform public.require_platform_admin();
  select * into inv from invoices where id = p_invoice for update;
  if inv.id is null then
    raise exception 'not_found';
  end if;
  if inv.status <> 'issued' then
    raise exception 'invalid_status';
  end if;
  update invoices
  set status = 'paid', paid_at = now(), paid_by = auth.uid(),
      payment_ref = nullif(left(trim(p_reference), 200), '')
  where id = inv.id;

  for line in
    select l.plan_id, l.plan_name, w.id as workspace_id, w.plan_id as current_plan, w.paid_until
    from invoice_lines l join workspaces w on w.id = l.workspace_id
    where l.invoice_id = inv.id
  loop
    until := case when line.current_plan = line.plan_id and line.paid_until > now()
                  then line.paid_until else now() end
             + make_interval(months => inv.months);
    perform public.put_on_plan(line.workspace_id, line.plan_id, until, 'invoice', inv.id);
    perform public.notify_billing(array[public.company_owner_of(line.workspace_id)],
                                  line.workspace_id, 'plan_active', line.plan_name);
  end loop;
end;
$$;

create function public.admin_void_invoice(p_invoice uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.require_platform_admin();
  update invoices set status = 'void', voided_at = now()
  where id = p_invoice and status = 'issued';
  if not found then
    raise exception 'invalid_status';
  end if;
  -- What was asked for is waiting again.
  update plan_requests r set status = 'pending', invoice_id = null
  where r.invoice_id = p_invoice and r.status = 'invoiced'
    and not exists (select 1 from plan_requests o
                    where o.workspace_id = r.workspace_id and o.status = 'pending');
end;
$$;

-- A plan given by hand: a trial, a pilot, or an agreement paid outside the
-- app. Without an end date it never runs out.
create function public.admin_set_workspace_plan(p_workspace uuid, p_plan text, p_until timestamptz)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.require_platform_admin();
  if not exists (select 1 from workspaces where id = p_workspace) then
    raise exception 'not_found';
  end if;
  if not exists (select 1 from plans where id = p_plan) then
    raise exception 'invalid_plan';
  end if;
  if p_until is not null and p_until <= now() then
    raise exception 'invalid_date';
  end if;
  perform public.put_on_plan(p_workspace, p_plan, p_until, 'admin');
  if p_plan <> 'free' then
    perform public.notify_billing(array[public.company_owner_of(p_workspace)], p_workspace,
                                  'plan_active', (select name from plans where id = p_plan));
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Daily: warn a week before paid time ends, and return workspaces a week
-- past it to the free plan.
-- ---------------------------------------------------------------------------

create function public.process_subscriptions()
returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  w       record;
  changed integer := 0;
begin
  for w in
    select ws.id, p.name as plan_name, ws.paid_until from workspaces ws join plans p on p.id = ws.plan_id
    where ws.plan_id <> 'free' and ws.paid_until is not null
      and ws.paid_until > now() and ws.paid_until <= now() + interval '7 days'
      and ws.ending_noticed_for is distinct from ws.paid_until
    for update of ws skip locked
  loop
    update workspaces set ending_noticed_for = w.paid_until where id = w.id;
    perform public.notify_billing(array[public.company_owner_of(w.id)], w.id, 'plan_ending',
                                  w.plan_name);
    changed := changed + 1;
  end loop;

  for w in
    select ws.id, p.name as plan_name from workspaces ws join plans p on p.id = ws.plan_id
    where ws.plan_id <> 'free' and ws.paid_until is not null
      and ws.paid_until < now() - interval '7 days'
    for update of ws skip locked
  loop
    perform public.put_on_plan(w.id, 'free', null, 'expired');
    perform public.notify_billing(array[public.company_owner_of(w.id)], w.id, 'plan_expired',
                                  w.plan_name);
    changed := changed + 1;
  end loop;
  return changed;
end;
$$;

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    -- The tasks migration already turned it on. On hosted Supabase even a
    -- "create extension if not exists" re-runs its setup script, which then
    -- fails ("dependent privileges exist"), so it is only created if missing.
    if not exists (select 1 from pg_extension where extname = 'pg_cron') then
      create extension pg_cron with schema pg_catalog;
    end if;
    perform cron.schedule('wasla-subscriptions', '0 6 * * *',
                          'select public.process_subscriptions()');
  else
    raise notice 'pg_cron is not available here; subscriptions are not checked daily';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Row Level Security: everything goes through the functions above, apart from
-- the countries list, which anyone signed in may read.
-- ---------------------------------------------------------------------------

alter table public.platform_admins   enable row level security;
alter table public.billing_countries enable row level security;
alter table public.exchange_rates    enable row level security;
alter table public.billing_settings  enable row level security;
alter table public.plan_requests     enable row level security;
alter table public.invoices          enable row level security;
alter table public.invoice_lines     enable row level security;
alter table public.plan_changes      enable row level security;

revoke all on public.platform_admins, public.billing_countries, public.exchange_rates,
              public.billing_settings, public.plan_requests, public.invoices,
              public.invoice_lines, public.plan_changes
from anon, authenticated;
revoke all on sequence public.invoice_numbers from anon, authenticated;

grant select on public.billing_countries to authenticated;
create policy billing_countries_read on public.billing_countries for select to authenticated
  using (true);

-- ---------------------------------------------------------------------------
-- Function privileges
-- ---------------------------------------------------------------------------

revoke execute on function
  public.is_platform_admin(),
  public.require_platform_admin(),
  public.country_rate(text),
  public.active_members(uuid),
  public.notify_billing(uuid[], uuid, text, text),
  public.company_owner_of(uuid),
  public.put_on_plan(uuid, text, timestamptz, text, uuid),
  public.my_billing_companies(),
  public.invoice_json(uuid),
  public.billing_overview(uuid),
  public.request_plan(uuid, text, integer, text),
  public.cancel_plan_request(uuid),
  public.admin_overview(),
  public.admin_companies(text),
  public.admin_requests(),
  public.admin_invoices(text),
  public.admin_rates(),
  public.admin_plans(),
  public.admin_billing_settings(),
  public.admin_set_rate(text, numeric),
  public.admin_update_plan(text, text, integer, integer, numeric, boolean),
  public.admin_update_billing_settings(text, text, text),
  public.admin_create_invoice(uuid, jsonb, integer, numeric, text, integer),
  public.admin_mark_invoice_paid(uuid, text),
  public.admin_void_invoice(uuid),
  public.admin_set_workspace_plan(uuid, text, timestamptz),
  public.process_subscriptions()
from public, anon, authenticated;

-- What the app calls. The admin_ functions check the caller themselves.
grant execute on function
  public.is_platform_admin(),
  public.my_billing_companies(),
  public.billing_overview(uuid),
  public.request_plan(uuid, text, integer, text),
  public.cancel_plan_request(uuid),
  public.admin_overview(),
  public.admin_companies(text),
  public.admin_requests(),
  public.admin_invoices(text),
  public.admin_rates(),
  public.admin_plans(),
  public.admin_billing_settings(),
  public.admin_set_rate(text, numeric),
  public.admin_update_plan(text, text, integer, integer, numeric, boolean),
  public.admin_update_billing_settings(text, text, text),
  public.admin_create_invoice(uuid, jsonb, integer, numeric, text, integer),
  public.admin_mark_invoice_paid(uuid, text),
  public.admin_void_invoice(uuid),
  public.admin_set_workspace_plan(uuid, text, timestamptz)
to authenticated;
