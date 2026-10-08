-- Wasla: join request follow-ups for the phase 1 app.
-- Admins can see who is asking to join before they decide, and people can
-- see and withdraw their own pending requests.

-- Anything created from here on is private until a migration grants it.
alter default privileges in schema public revoke execute on functions from public, anon;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;

create function public.asked_to_join_my_workspace(other uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from join_requests jr
    where jr.user_id = other and jr.status = 'pending'
      and public.is_workspace_admin(jr.workspace_id)
  );
$$;

create policy profiles_read_requesters on public.profiles for select to authenticated
  using (public.asked_to_join_my_workspace(id));

-- The requester cannot read the workspace row yet, so the name comes from here.
create function public.my_join_requests()
returns table (id uuid, workspace_id uuid, workspace_name text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select jr.id, w.id, w.name, jr.created_at
  from join_requests jr
  join workspaces w on w.id = jr.workspace_id
  where jr.user_id = auth.uid() and jr.status = 'pending'
  order by jr.created_at desc;
$$;

create function public.cancel_join_request(p_request_id uuid)
returns void
language sql security definer set search_path = public as $$
  update join_requests set status = 'cancelled'
  where id = p_request_id and user_id = auth.uid() and status = 'pending';
$$;

revoke execute on function
  public.asked_to_join_my_workspace(uuid),
  public.my_join_requests(),
  public.cancel_join_request(uuid)
from public, anon;

grant execute on function
  public.asked_to_join_my_workspace(uuid),
  public.my_join_requests(),
  public.cancel_join_request(uuid)
to authenticated;
