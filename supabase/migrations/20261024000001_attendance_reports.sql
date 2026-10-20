-- Attendance reports: one row per person per day over a period, for the
-- Excel and PDF files the app makes.
--
-- * Managers report on the people they look after: owners and admins on
--   everyone, project leads on the people of their projects.
-- * Optionally only one project's people, or only chosen people.
-- * Every day from the start to the end (never past today) is listed, with
--   the record when there is one; days before someone joined are left out
--   unless they have a record.

create function public.attendance_report(
  p_workspace uuid,
  p_from      date,
  p_to        date,
  p_project   uuid   default null,
  p_people    uuid[] default null
) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  st    attendance_settings%rowtype;
  today date;
  last  date;
begin
  if not public.is_attendance_manager(p_workspace) then
    raise exception 'not_allowed';
  end if;
  select * into st from attendance_settings where workspace_id = p_workspace;
  if st.workspace_id is null then
    raise exception 'attendance_off';
  end if;
  today := (now() at time zone st.timezone)::date;
  last := least(p_to, today);
  if p_from is null or p_to is null or p_from > p_to or last - p_from > 400 then
    raise exception 'invalid_period';
  end if;

  return jsonb_build_object(
    'workspace', (select name from workspaces where id = p_workspace),
    'from', p_from,
    'to', last,
    'timezone', st.timezone,
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'person_id', ap.id,
               'name', public.attendance_person_name(ap.id),
               'job_title', ap.job_title,
               'code', ap.code,
               'has_app', ap.user_id is not null,
               'project', (select name from projects where id = ap.project_id),
               'day', d.day,
               'day_off', extract(dow from d.day)::smallint = any (st.weekend_days),
               'in_at', r.in_at,
               'out_at', r.out_at,
               'late_minutes', coalesce(r.late_minutes, 0),
               'site', (select name from attendance_sites where id = r.in_site_id),
               'outside', coalesce(r.outside, false),
               'review', r.review,
               'in_by', (select full_name from profiles where id = r.in_by),
               'out_by', (select full_name from profiles where id = r.out_by))
             order by public.attendance_person_name(ap.id), ap.id, d.day)
      from attendance_people ap
      left join workspace_members wm on wm.workspace_id = ap.workspace_id and wm.user_id = ap.user_id
      cross join lateral (
        select g::date as day
        from generate_series(
          least(greatest(p_from, case when ap.user_id is null
                                      then (ap.created_at at time zone st.timezone)::date
                                      else (wm.joined_at at time zone st.timezone)::date end),
                -- A record from before joining (a correction) still shows.
                coalesce((select min(r2.day) from attendance_records r2
                          where r2.person_id = ap.id and r2.day >= p_from), last)),
          last, interval '1 day') g
      ) d
      left join attendance_records r on r.person_id = ap.id and r.day = d.day
      where ap.workspace_id = p_workspace
        and public.can_manage_attendance(ap.id)
        and (p_people is null or ap.id = any (p_people))
        and (p_project is null
             or ap.project_id = p_project
             or exists (select 1 from project_members pm
                        where pm.project_id = p_project and pm.user_id = ap.user_id))
        -- People who left or were removed still show for the days they have.
        and (r.id is not null
             or (ap.active and (ap.user_id is null or wm.status = 'active')))
    ), '[]'));
end;
$$;

revoke execute on function public.attendance_report(uuid, date, date, uuid, uuid[])
  from public, anon, authenticated;
grant execute on function public.attendance_report(uuid, date, date, uuid, uuid[])
  to authenticated;
