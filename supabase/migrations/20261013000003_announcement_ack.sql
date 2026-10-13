-- Announcements can ask their readers to confirm they have read them, and
-- whoever posts (or manages) them sees who read, who confirmed, and who
-- hasn't opened them yet.

alter table public.announcements
  add column needs_ack boolean not null default false;
alter table public.announcement_reads
  add column acknowledged_at timestamptz;

drop function public.post_announcement(uuid, uuid, text, boolean);
create function public.post_announcement(
  p_workspace uuid, p_project uuid, p_body text, p_pinned boolean default false,
  p_needs_ack boolean default false
) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  a uuid;
begin
  if not public.can_post_announcements(p_workspace, p_project) then
    raise exception 'not_allowed';
  end if;
  if p_project is not null
     and (select status from projects where id = p_project) <> 'active' then
    raise exception 'conversation_closed';
  end if;
  if (select count(*) from announcements
      where created_by = auth.uid() and created_at > now() - interval '1 day') >= 50 then
    raise exception 'too_many_requests';
  end if;

  insert into announcements (workspace_id, project_id, body, pinned, needs_ack, created_by)
  values (p_workspace, p_project, trim(p_body), coalesce(p_pinned, false),
          coalesce(p_needs_ack, false), auth.uid())
  returning id into a;
  return a;
end;
$$;

drop function public.announcements_for(uuid, uuid);
create function public.announcements_for(p_workspace uuid, p_project uuid default null)
returns table (
  id uuid, project_id uuid, body text, pinned boolean,
  author_id uuid, author_name text, created_at timestamptz,
  read_by_me boolean, read_count integer, audience integer,
  needs_ack boolean, acked_by_me boolean, ack_count integer
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
            and r.acknowledged_at is not null)
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

-- One waiting for confirmation stays on top of the chats until confirmed.
drop function public.unread_announcements(uuid);
create function public.unread_announcements(p_workspace uuid)
returns table (
  id uuid, project_id uuid, project_name text, project_color text,
  body text, author_name text, created_at timestamptz, needs_ack boolean
)
language sql stable security definer set search_path = public, pg_temp as $$
  select a.id, a.project_id, pr.name, pr.color, a.body, p.full_name, a.created_at, a.needs_ack
  from announcements a
  join profiles p on p.id = a.created_by
  left join projects pr on pr.id = a.project_id
  where a.workspace_id = p_workspace
    and public.is_workspace_member(p_workspace)
    and a.deleted_at is null
    and a.created_by <> auth.uid()
    and a.created_at > now() - interval '30 days'
    and (a.project_id is null
         or (pr.status = 'active'
             and exists (select 1 from project_members pm
                         where pm.project_id = a.project_id and pm.user_id = auth.uid())))
    and not exists (select 1 from announcement_reads r
                    where r.announcement_id = a.id and r.user_id = auth.uid()
                      and (not a.needs_ack or r.acknowledged_at is not null))
  order by a.created_at desc
  limit 20;
$$;

-- "I've read it", for an announcement that asks.
create function public.acknowledge_announcement(p_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  an announcements%rowtype;
begin
  select * into an from announcements where id = p_id and deleted_at is null;
  if an.id is null or not public.can_see_announcements(an.workspace_id, an.project_id) then
    raise exception 'not_allowed';
  end if;
  insert into announcement_reads (announcement_id, user_id, acknowledged_at)
  values (an.id, auth.uid(), now())
  on conflict (announcement_id, user_id)
  do update set acknowledged_at = coalesce(announcement_reads.acknowledged_at, now());
end;
$$;

-- Everyone an announcement is for, with when they read and confirmed it:
-- for its author and those who may post such announcements.
create function public.announcement_readers(p_id uuid)
returns table (user_id uuid, full_name text, read_at timestamptz, acknowledged_at timestamptz)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  an announcements%rowtype;
begin
  select * into an from announcements where id = p_id and deleted_at is null;
  if an.id is null
     or not public.can_see_announcements(an.workspace_id, an.project_id)
     or not (an.created_by = auth.uid()
             or public.can_post_announcements(an.workspace_id, an.project_id)) then
    raise exception 'not_allowed';
  end if;
  return query
    select au.user_id, p.full_name, r.read_at, r.acknowledged_at
    from public.announcement_audience(an.id) au
    join profiles p on p.id = au.user_id
    left join announcement_reads r on r.announcement_id = an.id and r.user_id = au.user_id
    where au.user_id <> an.created_by
    order by r.acknowledged_at nulls last, r.read_at nulls last, p.full_name;
end;
$$;

revoke execute on function
  public.post_announcement(uuid, uuid, text, boolean, boolean),
  public.announcements_for(uuid, uuid),
  public.unread_announcements(uuid),
  public.acknowledge_announcement(uuid),
  public.announcement_readers(uuid)
from public, anon;

grant execute on function
  public.post_announcement(uuid, uuid, text, boolean, boolean),
  public.announcements_for(uuid, uuid),
  public.unread_announcements(uuid),
  public.acknowledge_announcement(uuid),
  public.announcement_readers(uuid)
to authenticated;
