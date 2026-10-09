-- Phase 4: the website's pricing table.
--
-- The landing page shows the plans companies can ask for, with the prices the
-- platform admin set, so they never go out of date. This is the only thing in
-- public that callers who are not signed in can reach: plan names, limits and
-- monthly prices, nothing about companies or workspaces.

create function public.public_plans()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'name', name, 'max_members', max_members,
           'storage_gb', storage_gb, 'price_usd', price_usd_month)
         order by sort, id), '[]')
  from plans
  where offered;
$$;

revoke execute on function public.public_plans() from public;
grant execute on function public.public_plans() to anon, authenticated;
