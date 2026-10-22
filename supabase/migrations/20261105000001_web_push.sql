-- Desktop notifications in the browser (Web Push), alongside the phones'.
--
-- * A browser that allows notifications registers its push subscription
--   (the endpoint and its keys, as JSON) as a push token with platform
--   'web'; the same queue (push_outbox) feeds it.
-- * The push function signs what it sends to browsers with a key pair of its
--   own (VAPID). It makes the pair the first time it runs and keeps it here,
--   where only the database and the functions can read it; the app gets the
--   public half to subscribe with.

alter table public.push_config
  add column web_public_key  text,
  add column web_private_jwk jsonb;

-- For the app: the key browsers subscribe with; null until the push
-- function has made it.
create function public.web_push_key()
returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select web_public_key from push_config;
$$;

-- For the push function: the key pair, null when there is none yet.
create function public.web_push_keys(p_key text)
returns table (public_key text, private_jwk jsonb)
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.check_edge_key(p_key);
  return query select c.web_public_key, c.web_private_jwk from push_config c
               where c.web_public_key is not null;
end;
$$;

-- For the push function: keeps a new key pair unless one was kept already
-- (two runs at once), and returns the one kept.
create function public.save_web_push_keys(p_key text, p_public text, p_private jsonb)
returns table (public_key text, private_jwk jsonb)
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.check_edge_key(p_key);
  update push_config set web_public_key = p_public, web_private_jwk = p_private
  where web_public_key is null;
  return query select c.web_public_key, c.web_private_jwk from push_config c;
end;
$$;

-- Each row now says which kind of device it goes to.
drop function public.claim_push_batch(text, integer);
create function public.claim_push_batch(p_key text, p_limit integer default 500)
returns table (id bigint, token text, platform text, locale text, kind text,
               title text, actor text, body text, data jsonb)
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.check_edge_key(p_key);
  return query
  with picked as (
    select o.id from push_outbox o
    where o.sent_at is null and o.attempts < 3
      and o.created_at > now() - interval '1 hour'
      and (o.claimed_at is null or o.claimed_at < now() - interval '2 minutes')
    order by o.id
    limit least(greatest(p_limit, 1), 1000)
    for update skip locked
  ), claimed as (
    update push_outbox o set attempts = o.attempts + 1, claimed_at = now()
    from picked where o.id = picked.id
    returning o.*
  )
  select c.id, t.token, t.platform, t.locale, c.kind, c.title, c.actor, c.body, c.data
  from claimed c left join push_tokens t on t.user_id = c.user_id
  order by c.id;
end;
$$;

-- Every minute: also has the push function make its browser key pair if
-- there is none yet.
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
               and (claimed_at is null or claimed_at < now() - interval '2 minutes'))
     or (select web_public_key from push_config) is null then
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

revoke execute on function
  public.web_push_key(),
  public.web_push_keys(text),
  public.save_web_push_keys(text, text, jsonb),
  public.claim_push_batch(text, integer),
  public.push_tick()
from public, anon, authenticated;

grant execute on function public.web_push_key() to authenticated;
grant execute on function
  public.web_push_keys(text),
  public.save_web_push_keys(text, text, jsonb),
  public.claim_push_batch(text, integer)
to service_role;
