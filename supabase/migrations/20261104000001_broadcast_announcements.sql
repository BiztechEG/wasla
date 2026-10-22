-- One announcement to several workspaces at once, for whoever runs them
-- (the company's leadership), followed in one place: in each workspace, how
-- many it was for, read it, and confirmed it.
--
-- * Each workspace gets its own copy (its people, its reads); the copies
--   share a broadcast_id.
-- * Only workspace-wide announcements, and only to workspaces one is an
--   owner or admin of.

alter table public.announcements add column broadcast_id uuid;
create index announcements_broadcast_idx on public.announcements (broadcast_id)
  where broadcast_id is not null;

drop function public.announcements_for(uuid, uuid);

create function public.announcements_for(p_workspace uuid, p_project uuid default null)
returns table (
  id uuid, project_id uuid, body text, pinned boolean,
  author_id uuid, author_name text, created_at timestamptz,
  read_by_me boolean, read_count integer, audience integer,
  needs_ack boolean, acked_by_me boolean, ack_count integer,
  broadcast_id uuid
)
language sql stable security definer set search_path = public, pg_temp as $$
  select a.id, a.project_id, a.body, a.pinned,
         a.created_by, p.full_name, a.created_at,
         mine.user_id is not null,
         (select count(*)::int from announcement_reads r
          join public.announcement_audience(a.id) au on au.user_id = r.user_id
          where r.announcement_id = a.id and r.user_id <> a.created_by),
         (select count(*)::int from public.announcement_audience(a.id) au
          where au.user_id <> a.created_by),
         a.needs_ack,
         mine.acknowledged_at is not null,
         (select count(*)::int from announcement_reads r
          join public.announcement_audience(a.id) au on au.user_id = r.user_id
          where r.announcement_id = a.id and r.user_id <> a.created_by
            and r.acknowledged_at is not null),
         a.broadcast_id
  from announcements a
  join profiles p on p.id = a.created_by
  left join announcement_reads mine on mine.announcement_id = a.id and mine.user_id = auth.uid()
  where a.workspace_id = p_workspace
    and a.project_id is not distinct from p_project
    and a.deleted_at is null
    and public.can_see_announcements(p_workspace, p_project)
  order by a.pinned desc, a.created_at desc
  limit 100;
$$;

-- Posts the same announcement to every one of p_workspaces; returns the
-- broadcast's id.
create function public.post_broadcast(
  p_workspaces uuid[],
  p_body       text,
  p_pinned     boolean default false,
  p_needs_ack  boolean default false
) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  b  uuid := gen_random_uuid();
  ws uuid;
  a  uuid;
begin
  if coalesce(cardinality(p_workspaces), 0) = 0 or cardinality(p_workspaces) > 50 then
    raise exception 'invalid_workspaces';
  end if;
  if exists (select 1 from unnest(p_workspaces) w
             where not public.can_post_announcements(w, null)) then
    raise exception 'not_allowed';
  end if;
  foreach ws in array array(select distinct w from unnest(p_workspaces) w) loop
    a := public.post_announcement(ws, null, p_body, p_pinned, p_needs_ack);
    update announcements set broadcast_id = b where id = a;
  end loop;
  return b;
end;
$$;

-- How a broadcast is doing in each workspace one runs.
create function public.broadcast_reach(p_broadcast uuid)
returns table (workspace_id uuid, workspace_name text, audience integer,
               read_count integer, ack_count integer)
language sql stable security definer set search_path = public, pg_temp as $$
  select a.workspace_id, w.name,
         (select count(*)::int from public.announcement_audience(a.id) au
          where au.user_id <> a.created_by),
         (select count(*)::int from announcement_reads r
          join public.announcement_audience(a.id) au on au.user_id = r.user_id
          where r.announcement_id = a.id and r.user_id <> a.created_by),
         (select count(*)::int from announcement_reads r
          join public.announcement_audience(a.id) au on au.user_id = r.user_id
          where r.announcement_id = a.id and r.user_id <> a.created_by
            and r.acknowledged_at is not null)
  from announcements a
  join workspaces w on w.id = a.workspace_id and w.deleted_at is null
  where a.broadcast_id = p_broadcast and a.deleted_at is null
    and (a.created_by = auth.uid() or public.is_workspace_admin(a.workspace_id))
  order by w.name;
$$;

revoke execute on function
  public.announcements_for(uuid, uuid),
  public.post_broadcast(uuid[], text, boolean, boolean),
  public.broadcast_reach(uuid)
from public, anon;
grant execute on function
  public.announcements_for(uuid, uuid),
  public.post_broadcast(uuid[], text, boolean, boolean),
  public.broadcast_reach(uuid)
to authenticated;
