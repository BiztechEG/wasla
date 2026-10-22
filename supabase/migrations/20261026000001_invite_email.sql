-- Invitations by email: the invited person gets an email, so they know to
-- download Wasla and sign in with that address.
--
-- * Each new invitation to an email queues one message (email_outbox), in
--   the invited person's language when they have an account, else in the
--   inviting admin's.
-- * The Edge Function `email` sends them through the SMTP server in its
--   secrets (SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, SMTP_FROM). The
--   database calls it as soon as something is queued, and push_tick() every
--   minute retries: three tries at most, nothing older than a day.
-- * Without those secrets the function sends nothing and the queue waits.

create table public.email_outbox (
  id           bigint generated always as identity primary key,
  kind         text not null check (kind in ('invite')),
  to_email     text not null check (length(to_email) <= 320),
  locale       text not null default 'ar' check (locale in ('ar', 'en')),
  data         jsonb not null default '{}',
  created_at   timestamptz not null default clock_timestamp(),
  attempts     integer not null default 0,
  claimed_at   timestamptz,
  sent_at      timestamptz
);

create index email_outbox_pending_idx on public.email_outbox (id) where sent_at is null;

alter table public.email_outbox enable row level security;
revoke all on public.email_outbox from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Queueing
-- ---------------------------------------------------------------------------

create function public.invites_email()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  lang text;
begin
  if new.email is null then
    return null;
  end if;
  select coalesce(
           (select p.locale from profiles p where lower(p.email) = lower(new.email) limit 1),
           (select p.locale from profiles p where p.id = new.invited_by),
           'ar')
  into lang;
  insert into email_outbox (kind, to_email, locale, data)
  select 'invite', lower(new.email), lang,
         jsonb_build_object(
           'workspace', w.name,
           'company', c.name,
           'inviter', p.full_name,
           'role', new.role::text,
           'expires_at', new.expires_at)
  from workspaces w
  join companies c on c.id = w.company_id
  join profiles p on p.id = new.invited_by
  where w.id = new.workspace_id;
  return null;
end;
$$;

create trigger invites_email after insert on public.invites
  for each row execute function public.invites_email();

create function public.email_outbox_kick()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.call_edge('email');
  return null;
end;
$$;

create trigger email_outbox_kick after insert on public.email_outbox
  for each statement execute function public.email_outbox_kick();

-- ---------------------------------------------------------------------------
-- For the email function
-- ---------------------------------------------------------------------------

-- Takes up to p_limit queued emails; each is tried three times at most, ten
-- minutes apart, and dropped after a day.
create function public.claim_email_batch(p_key text, p_limit integer default 50)
returns table (id bigint, kind text, to_email text, locale text, data jsonb)
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.check_edge_key(p_key);
  return query
  with picked as (
    select o.id from email_outbox o
    where o.sent_at is null and o.attempts < 3
      and o.created_at > now() - interval '1 day'
      and (o.claimed_at is null or o.claimed_at < now() - interval '10 minutes')
    order by o.id
    limit least(greatest(p_limit, 1), 200)
    for update skip locked
  )
  update email_outbox o set attempts = o.attempts + 1, claimed_at = now()
  from picked where o.id = picked.id
  returning o.id, o.kind, o.to_email, o.locale, o.data;
end;
$$;

create function public.finish_email_batch(p_key text, p_ids bigint[])
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.check_edge_key(p_key);
  update email_outbox set sent_at = now() where id = any (p_ids) and sent_at is null;
end;
$$;

-- Every minute: also retries emails, and forgets old ones.
create or replace function public.push_tick()
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  delete from push_outbox where created_at < now() - interval '3 days';
  delete from push_tokens where updated_at < now() - interval '90 days';
  delete from email_outbox where created_at < now() - interval '7 days';
  if exists (select 1 from push_outbox
             where sent_at is null and attempts < 3
               and created_at > now() - interval '1 hour'
               and (claimed_at is null or claimed_at < now() - interval '2 minutes')) then
    perform public.call_edge('push');
  end if;
  if exists (select 1 from email_outbox
             where sent_at is null and attempts < 3
               and created_at > now() - interval '1 day'
               and (claimed_at is null or claimed_at < now() - interval '10 minutes')) then
    perform public.call_edge('email');
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------

revoke execute on function
  public.invites_email(),
  public.email_outbox_kick(),
  public.claim_email_batch(text, integer),
  public.finish_email_batch(text, bigint[]),
  public.push_tick()
from public, anon, authenticated;

-- The Edge Function calls in with the server key.
grant execute on function
  public.claim_email_batch(text, integer),
  public.finish_email_batch(text, bigint[])
to service_role;
