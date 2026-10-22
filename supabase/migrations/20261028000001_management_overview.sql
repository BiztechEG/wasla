-- The management overview: how each workspace one runs is doing, in
-- numbers only.
--
-- * A company owner sees every workspace of their companies; a workspace's
--   owners and admins see that workspace.
-- * Per workspace: people, projects, open, late, in review and recently done
--   tasks (with the week before, to compare), project chat activity, and
--   today's attendance when it is on. Per project: its tasks.
-- * Activity is counted, never read: no message, no task title in a private
--   chat, and nothing from private chats at all.

create function public.management_overview()
returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  with mine as (
    select w.id, w.name, co.name as company
    from workspaces w
    join companies co on co.id = w.company_id
    where w.deleted_at is null
      and auth.uid() is not null
      and (co.owner_id = auth.uid()
           or exists (select 1 from workspace_members wm
                      where wm.workspace_id = w.id and wm.user_id = auth.uid()
                        and wm.status = 'active' and wm.role in ('owner', 'admin')))
  ),
  live as (
    -- Tasks in active projects of those workspaces.
    select t.*
    from tasks t
    join projects p on p.id = t.project_id and p.status = 'active'
    where t.deleted_at is null and p.workspace_id in (select id from mine)
  )
  select coalesce(jsonb_agg(row order by row ->> 'workspace_name'), '[]')
  from (
    select jsonb_build_object(
      'workspace_id', m.id,
      'workspace_name', m.name,
      'company_name', m.company,
      'members', (select count(*) from workspace_members wm
                  where wm.workspace_id = m.id and wm.status = 'active'),
      'projects', (select count(*) from projects p
                   where p.workspace_id = m.id and p.status = 'active'),
      'open', (select count(*) from live t
               where t.workspace_id = m.id and t.status <> 'done'),
      'late', (select count(*) from live t
               where t.workspace_id = m.id and t.status <> 'done' and t.due_at < now()),
      'review', (select count(*) from live t
                 where t.workspace_id = m.id and t.status = 'review'),
      'done_week', (select count(*) from live t
                    where t.workspace_id = m.id and t.status = 'done'
                      and t.done_at >= now() - interval '7 days'),
      'done_week_before', (select count(*) from live t
                           where t.workspace_id = m.id and t.status = 'done'
                             and t.done_at >= now() - interval '14 days'
                             and t.done_at < now() - interval '7 days'),
      'messages_week', (select count(*) from messages ms
                        join conversations c on c.id = ms.conversation_id
                        where ms.workspace_id = m.id and c.kind = 'project'
                          and ms.deleted_at is null
                          and ms.created_at >= now() - interval '7 days'),
      'active_people_week', (select count(distinct ms.sender_id) from messages ms
                             join conversations c on c.id = ms.conversation_id
                             where ms.workspace_id = m.id and c.kind = 'project'
                               and ms.deleted_at is null
                               and ms.created_at >= now() - interval '7 days'),
      'attendance', (
        select case when st.workspace_id is null or not st.enabled then null else
          jsonb_build_object(
            'day_off', extract(dow from (now() at time zone st.timezone))::smallint
                       = any (st.weekend_days),
            'people', (select count(*) from attendance_people ap
                       left join workspace_members wm
                         on wm.workspace_id = ap.workspace_id and wm.user_id = ap.user_id
                       where ap.workspace_id = m.id and ap.active
                         and (ap.user_id is null or wm.status = 'active')),
            'present', (select count(*) from attendance_records r
                        join attendance_people ap on ap.id = r.person_id and ap.active
                        where r.workspace_id = m.id
                          and r.day = (now() at time zone st.timezone)::date),
            'late', (select count(*) from attendance_records r
                     join attendance_people ap on ap.id = r.person_id and ap.active
                     where r.workspace_id = m.id and r.late_minutes > 0
                       and r.day = (now() at time zone st.timezone)::date))
        end
        from (select 1) one
        left join attendance_settings st on st.workspace_id = m.id),
      'project_list', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'id', p.id, 'name', p.name, 'color', p.color,
                 'total', (select count(*) from live t where t.project_id = p.id),
                 'open', (select count(*) from live t
                          where t.project_id = p.id and t.status <> 'done'),
                 'late', (select count(*) from live t
                          where t.project_id = p.id and t.status <> 'done'
                            and t.due_at < now()),
                 'done', (select count(*) from live t
                          where t.project_id = p.id and t.status = 'done'))
               order by p.name), '[]')
        from projects p
        where p.workspace_id = m.id and p.status = 'active')
    ) as row
    from mine m
  ) rows;
$$;

revoke execute on function public.management_overview() from public, anon, authenticated;
grant execute on function public.management_overview() to authenticated;
