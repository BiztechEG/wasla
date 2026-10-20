-- Attendance for managers: the team's day, reviews, workers without the app,
-- roll call, corrections and reminders.
--
-- * Managers are workspace owners and admins (everyone) and project leads
--   (the people in their active projects, and workers added to them).
-- * Workers without the app are added once by a manager; managers then check
--   them in and out. Each plan has a number of free workers (by default
--   twice its seats); past that, the plan's price per extra worker is added
--   to the invoice, or adding stops when the plan has no such price.
-- * A manager records check-ins and check-outs for several people at once,
--   each at their own time (never in the future). Changes to a record are
--   logged with who made them.
-- * People ask for a correction of a day; their manager accepts or rejects it.
-- * Reminders: a phone notification when someone has not checked in after
--   their shift started, or has not checked out after it ended.
-- * Managers cannot review or change their own records, apart from
--   workspace owners and admins.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

alter table public.plans
  add column free_workers     integer check (free_workers >= 0),
  add column extra_worker_usd numeric(10, 2) not null default 0 check (extra_worker_usd >= 0);

alter table public.invoice_lines
  add column extra_workers    integer not null default 0,
  add column extra_worker_usd numeric(10, 2) not null default 0;

create table public.attendance_edits (
  id           bigint generated always as identity primary key,
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  person_id    uuid not null references public.attendance_people (id) on delete cascade,
  record_id    uuid references public.attendance_records (id) on delete set null,
  day          date not null,
  -- in, out: a time changed; review: accepted or rejected; deleted: removed.
  field        text not null check (field in ('in', 'out', 'review', 'deleted')),
  old_at       timestamptz,
  new_at       timestamptz,
  detail       text check (length(detail) <= 300),
  edited_by    uuid references public.profiles (id) on delete set null,
  edited_at    timestamptz not null default now()
);

create index attendance_edits_record_idx on public.attendance_edits (record_id);
create index attendance_edits_person_idx on public.attendance_edits (person_id, day);

create table public.attendance_fixes (
  id            uuid primary key default gen_random_uuid(),
  workspace_id  uuid not null references public.workspaces (id) on delete cascade,
  person_id     uuid not null references public.attendance_people (id) on delete cascade,
  day           date not null,
  in_at         timestamptz,
  out_at        timestamptz,
  note          text not null check (length(trim(note)) between 1 and 300),
  status        text not null default 'pending'
                check (status in ('pending', 'accepted', 'rejected', 'cancelled')),
  decided_by    uuid references public.profiles (id) on delete set null,
  decided_at    timestamptz,
  decision_note text check (length(decision_note) <= 300),
  created_at    timestamptz not null default now(),
  check (in_at is not null or out_at is not null),
  check (out_at is null or in_at is null or out_at > in_at)
);

create unique index attendance_fixes_pending_idx
  on public.attendance_fixes (person_id, day) where status = 'pending';
create index attendance_fixes_workspace_idx on public.attendance_fixes (workspace_id, status);

create table public.attendance_reminders_sent (
  person_id uuid not null references public.attendance_people (id) on delete cascade,
  day       date not null,
  kind      text not null check (kind in ('in', 'out')),
  sent_at   timestamptz not null default now(),
  primary key (person_id, day, kind)
);

alter table public.attendance_edits          enable row level security;
alter table public.attendance_fixes          enable row level security;
alter table public.attendance_reminders_sent enable row level security;
revoke all on public.attendance_edits, public.attendance_fixes, public.attendance_reminders_sent
  from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Whether the signed-in user manages anyone's attendance in a workspace.
create function public.is_attendance_manager(p_workspace uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select public.is_workspace_admin(p_workspace)
      or exists (select 1 from projects pr
                 where pr.workspace_id = p_workspace and pr.status = 'active'
                   and pr.id in (select public.my_managed_project_ids()));
$$;

-- Managers may change records, apart from their own (owners and admins may).
create function public.check_attendance_editor(p_person uuid)
returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  ap attendance_people%rowtype;
begin
  select * into ap from attendance_people where id = p_person;
  if ap.id is null or not public.can_manage_attendance(p_person)
     or (ap.user_id = auth.uid() and not public.is_workspace_admin(ap.workspace_id)) then
    raise exception 'not_allowed';
  end if;
end;
$$;

-- When a check-in at p_at on p_day starts, and how late it is. Days off are
-- never late.
create function public.attendance_lateness(p_person uuid, p_day date, p_at timestamptz,
                                           out shift_start timestamptz, out late integer)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  ap    attendance_people%rowtype;
  st    attendance_settings%rowtype;
  hours record;
begin
  late := 0;
  select * into ap from attendance_people where id = p_person;
  select * into st from attendance_settings where workspace_id = ap.workspace_id;
  select * into hours from public.attendance_hours(ap.workspace_id, public.attendance_shift_of(p_person), p_day);
  shift_start := hours.start_at;
  if hours.start_at is not null
     and not (extract(dow from p_day)::smallint = any (st.weekend_days))
     and p_at > hours.start_at + make_interval(mins => hours.grace) then
    late := floor(extract(epoch from p_at - hours.start_at) / 60);
  end if;
end;
$$;

-- Who hears about a person's attendance: the leads of their active projects
-- (for a worker, the project they were added to), else the workspace's
-- owners and admins. Never the person.
create function public.attendance_managers_of(p_person uuid)
returns uuid[]
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  ap    attendance_people%rowtype;
  leads uuid[];
begin
  select * into ap from attendance_people where id = p_person;
  select array_agg(distinct pm.user_id) into leads
  from project_members pm
  join projects pr on pr.id = pm.project_id
  join workspace_members wm on wm.workspace_id = pr.workspace_id and wm.user_id = pm.user_id
                            and wm.status = 'active'
  where pr.workspace_id = ap.workspace_id and pr.status = 'active' and pm.role = 'lead'
    and pm.user_id is distinct from ap.user_id
    and (pr.id = ap.project_id
         or exists (select 1 from project_members m
                    where m.project_id = pr.id and m.user_id = ap.user_id));
  if leads is not null then
    return leads;
  end if;
  return (select array_agg(wm.user_id) from workspace_members wm
          where wm.workspace_id = ap.workspace_id and wm.status = 'active'
            and wm.role in ('owner', 'admin') and wm.user_id is distinct from ap.user_id);
end;
$$;

create function public.attendance_person_name(p_person uuid)
returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(pr.full_name, ap.full_name)
  from attendance_people ap left join profiles pr on pr.id = ap.user_id
  where ap.id = p_person;
$$;

-- Free workers on a workspace's plan (null = no limit), and the price of
-- each one past that (0 = no more can be added).
create function public.attendance_worker_quota(p_workspace uuid,
                                               out used integer, out free integer,
                                               out extra_usd numeric)
language sql stable security definer set search_path = public, pg_temp as $$
  select (select count(*)::integer from attendance_people
          where workspace_id = p_workspace and user_id is null and active),
         case when p.max_members is null and p.free_workers is null then null
              else coalesce(p.free_workers, p.max_members * 2) end,
         p.extra_worker_usd
  from workspaces w join plans p on p.id = w.plan_id
  where w.id = p_workspace;
$$;

-- One row for every active member, so the team's day lists people who have
-- never checked in.
create function public.attendance_sync_people(p_workspace uuid)
returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into attendance_people (workspace_id, user_id)
  select wm.workspace_id, wm.user_id from workspace_members wm
  where wm.workspace_id = p_workspace and wm.status = 'active'
  on conflict (workspace_id, user_id) do nothing;
$$;

create function public.attendance_person_json(p_person uuid, p_day date)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  ap    attendance_people%rowtype;
  st    attendance_settings%rowtype;
  hours record;
  shift uuid;
  r     attendance_records%rowtype;
begin
  select * into ap from attendance_people where id = p_person;
  select * into st from attendance_settings where workspace_id = ap.workspace_id;
  shift := public.attendance_shift_of(p_person);
  select * into hours from public.attendance_hours(ap.workspace_id, shift, p_day);
  select * into r from attendance_records where person_id = p_person and day = p_day;
  return jsonb_build_object(
    'id', ap.id,
    'user_id', ap.user_id,
    'name', public.attendance_person_name(ap.id),
    'job_title', ap.job_title,
    'phone', ap.phone,
    'code', ap.code,
    'photo_path', ap.photo_path,
    'project_id', ap.project_id,
    'project_name', (select name from projects where id = ap.project_id),
    'site_id', ap.site_id,
    'site_name', (select name from attendance_sites where id = ap.site_id),
    'shift_id', ap.shift_id,
    'shift', (select jsonb_build_object('name', sh.name, 'start_at', hours.start_at,
                                         'end_at', hours.end_at, 'grace', hours.grace)
              from attendance_shifts sh where sh.id = shift),
    'day_off', extract(dow from p_day)::smallint = any (st.weekend_days),
    'record', case when r.id is not null then public.attendance_record_json(r) end);
end;
$$;

-- ---------------------------------------------------------------------------
-- The team's day
-- ---------------------------------------------------------------------------

-- Everyone the signed-in manager looks after, with their record on p_day
-- (today when null), optionally only one project's people.
create function public.attendance_board(p_workspace uuid, p_day date default null,
                                        p_project uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  st    attendance_settings%rowtype;
  d     date;
  quota record;
begin
  if not public.is_attendance_manager(p_workspace) then
    raise exception 'not_allowed';
  end if;
  select * into st from attendance_settings where workspace_id = p_workspace;
  if st.workspace_id is null or not st.enabled then
    raise exception 'attendance_off';
  end if;
  perform public.attendance_sync_people(p_workspace);
  d := coalesce(p_day, (now() at time zone st.timezone)::date);
  select * into quota from public.attendance_worker_quota(p_workspace);

  return jsonb_build_object(
    'day', d,
    'today', (now() at time zone st.timezone)::date,
    'is_admin', public.is_workspace_admin(p_workspace),
    'projects', coalesce((select jsonb_agg(jsonb_build_object('id', pr.id, 'name', pr.name)
                                           order by pr.name)
                          from projects pr
                          where pr.workspace_id = p_workspace and pr.status = 'active'
                            and pr.id in (select public.my_managed_project_ids())), '[]'),
    'sites', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name)
                                        order by s.name)
                       from attendance_sites s where s.workspace_id = p_workspace), '[]'),
    'shifts', coalesce((select jsonb_agg(jsonb_build_object('id', sh.id, 'name', sh.name)
                                         order by sh.created_at, sh.id)
                        from attendance_shifts sh where sh.workspace_id = p_workspace), '[]'),
    'workers', jsonb_build_object('used', quota.used, 'free', quota.free,
                                  'extra_usd', quota.extra_usd),
    'requests', (select count(*) from attendance_records r
                 where r.workspace_id = p_workspace and r.review = 'pending'
                   and public.can_manage_attendance(r.person_id))
              + (select count(*) from attendance_fixes f
                 where f.workspace_id = p_workspace and f.status = 'pending'
                   and public.can_manage_attendance(f.person_id)),
    'people', coalesce((
      select jsonb_agg(public.attendance_person_json(ap.id, d)
                       order by public.attendance_person_name(ap.id))
      from attendance_people ap
      where ap.workspace_id = p_workspace and ap.active
        and (ap.user_id is null
             or exists (select 1 from workspace_members wm
                        where wm.workspace_id = p_workspace and wm.user_id = ap.user_id
                          and wm.status = 'active'))
        and public.can_manage_attendance(ap.id)
        and (p_project is null
             or ap.project_id = p_project
             or exists (select 1 from project_members pm
                        where pm.project_id = p_project and pm.user_id = ap.user_id))), '[]'));
end;
$$;

-- One person's day for a manager: the record, and what was changed on it.
create function public.attendance_person_day(p_person uuid, p_day date)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.can_see_attendance(p_person) then
    raise exception 'not_allowed';
  end if;
  return public.attendance_person_json(p_person, p_day)
    || jsonb_build_object(
         'can_edit', public.can_manage_attendance(p_person)
                     and ((select user_id from attendance_people where id = p_person)
                            is distinct from auth.uid()
                          or public.is_workspace_admin(
                               (select workspace_id from attendance_people where id = p_person))),
         'edits', coalesce((select jsonb_agg(jsonb_build_object(
                     'field', e.field, 'old_at', e.old_at, 'new_at', e.new_at,
                     'detail', e.detail, 'by', (select full_name from profiles where id = e.edited_by),
                     'at', e.edited_at) order by e.edited_at desc, e.id desc)
                   from attendance_edits e where e.person_id = p_person and e.day = p_day), '[]'),
         'fix', (select jsonb_build_object('id', f.id, 'day', f.day, 'in_at', f.in_at, 'out_at', f.out_at,
                                           'note', f.note, 'status', f.status)
                 from attendance_fixes f
                 where f.person_id = p_person and f.day = p_day
                 order by f.created_at desc limit 1));
end;
$$;

-- ---------------------------------------------------------------------------
-- Reviewing check-ins from outside
-- ---------------------------------------------------------------------------

create function public.review_attendance(p_record uuid, p_accept boolean)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r attendance_records%rowtype;
begin
  select * into r from attendance_records where id = p_record for update;
  if r.id is null then
    raise exception 'not_found';
  end if;
  perform public.check_attendance_editor(r.person_id);
  if r.review <> 'pending' then
    raise exception 'already_reviewed';
  end if;
  update attendance_records
  set review = case when p_accept then 'accepted' else 'rejected' end,
      reviewed_by = auth.uid(), reviewed_at = now()
  where id = r.id;
  insert into attendance_edits (workspace_id, person_id, record_id, day, field, detail, edited_by)
  values (r.workspace_id, r.person_id, r.id, r.day, 'review',
          case when p_accept then 'accepted' else 'rejected' end, auth.uid());
  perform public.queue_push(
    array[(select user_id from attendance_people where id = r.person_id)], r.workspace_id,
    case when p_accept then 'attendance_accepted' else 'attendance_rejected' end,
    (select name from workspaces where id = r.workspace_id),
    (select full_name from profiles where id = auth.uid()), r.day::text,
    jsonb_build_object('type', 'attendance'));
end;
$$;

-- ---------------------------------------------------------------------------
-- Workers without the app
-- ---------------------------------------------------------------------------

-- Adds a worker (p_id null) or changes one. Leads add workers to one of
-- their projects; owners and admins to any project or none.
create function public.save_attendance_worker(
  p_workspace uuid, p_id uuid, p_name text, p_job text, p_phone text, p_code text,
  p_project uuid, p_site uuid, p_shift uuid, p_photo text default null
) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  ap    attendance_people%rowtype;
  quota record;
  w     uuid;
begin
  if not exists (select 1 from attendance_settings where workspace_id = p_workspace and enabled) then
    raise exception 'attendance_off';
  end if;
  if not public.is_workspace_admin(p_workspace)
     and (p_project is null or p_project not in (select public.my_managed_project_ids())) then
    raise exception 'not_allowed';
  end if;
  if p_project is not null and not exists (select 1 from projects where id = p_project
                                           and workspace_id = p_workspace and status = 'active') then
    raise exception 'not_found';
  end if;
  if (p_site is not null and not exists (select 1 from attendance_sites
                                         where id = p_site and workspace_id = p_workspace))
     or (p_shift is not null and not exists (select 1 from attendance_shifts
                                             where id = p_shift and workspace_id = p_workspace)) then
    raise exception 'not_found';
  end if;
  if length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'name_required';
  end if;

  if p_id is null then
    perform 1 from workspaces where id = p_workspace for update;
    select * into quota from public.attendance_worker_quota(p_workspace);
    if quota.free is not null and quota.used >= quota.free and quota.extra_usd = 0 then
      raise exception 'workers_limit';
    end if;
    perform public.check_attendance_photo(p_workspace, p_photo);
    insert into attendance_people (workspace_id, full_name, job_title, phone, code, photo_path,
                                   project_id, site_id, shift_id, created_by)
    values (p_workspace, trim(p_name), nullif(trim(p_job), ''), nullif(trim(p_phone), ''),
            nullif(trim(p_code), ''), p_photo, p_project, p_site, p_shift, auth.uid())
    returning id into w;
    return w;
  end if;

  select * into ap from attendance_people where id = p_id and workspace_id = p_workspace;
  if ap.id is null or ap.user_id is not null or not ap.active then
    raise exception 'not_found';
  end if;
  if not public.can_manage_attendance(ap.id) then
    raise exception 'not_allowed';
  end if;
  if p_photo is distinct from ap.photo_path then
    perform public.check_attendance_photo(p_workspace, p_photo);
  end if;
  update attendance_people
  set full_name = trim(p_name), job_title = nullif(trim(p_job), ''),
      phone = nullif(trim(p_phone), ''), code = nullif(trim(p_code), ''),
      photo_path = p_photo, project_id = p_project, site_id = p_site, shift_id = p_shift
  where id = ap.id;
  return ap.id;
end;
$$;

-- Takes a worker off the list; their days stay in the reports.
create function public.remove_attendance_worker(p_person uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.can_manage_attendance(p_person) then
    raise exception 'not_allowed';
  end if;
  update attendance_people set active = false where id = p_person and user_id is null;
  if not found then
    raise exception 'not_found';
  end if;
end;
$$;

-- The branch and shift of someone with the app (null = the default).
create function public.assign_attendance(p_person uuid, p_site uuid, p_shift uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  ap attendance_people%rowtype;
begin
  select * into ap from attendance_people where id = p_person;
  perform public.check_attendance_editor(p_person);
  if (p_site is not null and not exists (select 1 from attendance_sites
                                         where id = p_site and workspace_id = ap.workspace_id))
     or (p_shift is not null and not exists (select 1 from attendance_shifts
                                             where id = p_shift and workspace_id = ap.workspace_id)) then
    raise exception 'not_found';
  end if;
  update attendance_people set site_id = p_site, shift_id = p_shift where id = p_person;
end;
$$;

-- ---------------------------------------------------------------------------
-- Roll call: a manager checks people in or out
-- ---------------------------------------------------------------------------

-- p_kind is 'in' or 'out'; p_entries is [{"person": id, "at": time}]. Times
-- must not be in the future nor more than 31 days back. The manager's
-- location and an optional group photo are kept on each record. Returns how
-- many were recorded and who was skipped (already in, or not in).
create function public.attendance_roll_call(
  p_workspace uuid, p_kind text, p_entries jsonb,
  p_lat double precision default null, p_lng double precision default null,
  p_accuracy integer default null, p_photo text default null
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me      uuid := auth.uid();
  st      attendance_settings%rowtype;
  e       jsonb;
  person  uuid;
  at      timestamptz;
  d       date;
  late    record;
  site    uuid;
  dist    integer;
  r       attendance_records%rowtype;
  done    integer := 0;
  skipped uuid[] := '{}';
begin
  select * into st from attendance_settings where workspace_id = p_workspace;
  if st.workspace_id is null or not st.enabled then
    raise exception 'attendance_off';
  end if;
  if p_kind not in ('in', 'out') then
    raise exception 'invalid_kind';
  end if;
  if jsonb_typeof(p_entries) is distinct from 'array' or jsonb_array_length(p_entries) = 0
     or jsonb_array_length(p_entries) > 500 then
    raise exception 'invalid_items';
  end if;
  if (p_lat is null) <> (p_lng is null) or p_lat not between -90 and 90
     or p_lng not between -180 and 180 then
    raise exception 'location_required';
  end if;
  perform public.check_attendance_photo(p_workspace, p_photo);

  for e in select * from jsonb_array_elements(p_entries) loop
    person := (e ->> 'person')::uuid;
    at := (e ->> 'at')::timestamptz;
    if not exists (select 1 from attendance_people where id = person
                   and workspace_id = p_workspace and active) then
      raise exception 'not_found';
    end if;
    perform public.check_attendance_editor(person);
    if at is null or at > now() + interval '1 minute' then
      raise exception 'future_time';
    end if;
    if at < now() - interval '31 days' then
      raise exception 'too_old';
    end if;
    perform 1 from attendance_people where id = person for update;

    if p_kind = 'in' then
      d := (at at time zone st.timezone)::date;
      if exists (select 1 from attendance_records where person_id = person and day = d) then
        skipped := skipped || person;
        continue;
      end if;
      select * into late from public.attendance_lateness(person, d, at);
      site := null;
      dist := null;
      if p_lat is not null then
        select ap.site_id, ap.distance_m into site, dist
        from public.attendance_place(person, p_lat, p_lng, p_accuracy) ap;
      end if;
      insert into attendance_records (workspace_id, person_id, day, shift_start, late_minutes,
                                      in_at, in_lat, in_lng, in_accuracy_m, in_site_id,
                                      in_distance_m, in_photo_path, in_by)
      values (p_workspace, person, d, late.shift_start, late.late, at, p_lat, p_lng, p_accuracy,
              site, dist, p_photo, me);
    else
      select * into r from attendance_records
      where person_id = person and out_at is null and in_at < at and in_at > at - interval '24 hours'
      order by in_at desc limit 1
      for update;
      if r.id is null then
        skipped := skipped || person;
        continue;
      end if;
      site := null;
      dist := null;
      if p_lat is not null then
        select ap.site_id, ap.distance_m into site, dist
        from public.attendance_place(person, p_lat, p_lng, p_accuracy) ap;
      end if;
      update attendance_records
      set out_at = at, out_lat = p_lat, out_lng = p_lng, out_site_id = site,
          out_distance_m = dist, out_photo_path = p_photo, out_by = me
      where id = r.id;
    end if;
    done := done + 1;
  end loop;
  return jsonb_build_object('recorded', done, 'skipped', to_jsonb(skipped));
end;
$$;

-- Changes a record's times; each change is logged.
create function public.set_attendance_times(p_record uuid, p_in timestamptz, p_out timestamptz,
                                            p_note text default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r attendance_records%rowtype;
begin
  select * into r from attendance_records where id = p_record for update;
  if r.id is null then
    raise exception 'not_found';
  end if;
  perform public.check_attendance_editor(r.person_id);
  perform public.apply_attendance_times(r, p_in, p_out, p_note);
end;
$$;

-- Sets a record's times (used by managers' changes and accepted corrections).
create function public.apply_attendance_times(r attendance_records, p_in timestamptz,
                                              p_out timestamptz, p_note text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  late record;
begin
  if p_in is null or p_in > now() + interval '1 minute' or p_out > now() + interval '1 minute' then
    raise exception 'future_time';
  end if;
  if p_out is not null and p_out <= p_in then
    raise exception 'invalid_hours';
  end if;
  select * into late from public.attendance_lateness(r.person_id, r.day, p_in);
  update attendance_records
  set in_at = p_in, out_at = p_out, late_minutes = late.late,
      shift_start = coalesce(late.shift_start, shift_start),
      out_by = case when p_out is distinct from r.out_at then auth.uid() else out_by end
  where id = r.id;
  if p_in is distinct from r.in_at then
    insert into attendance_edits (workspace_id, person_id, record_id, day, field, old_at, new_at,
                                  detail, edited_by)
    values (r.workspace_id, r.person_id, r.id, r.day, 'in', r.in_at, p_in,
            nullif(left(trim(p_note), 300), ''), auth.uid());
  end if;
  if p_out is distinct from r.out_at then
    insert into attendance_edits (workspace_id, person_id, record_id, day, field, old_at, new_at,
                                  detail, edited_by)
    values (r.workspace_id, r.person_id, r.id, r.day, 'out', r.out_at, p_out,
            nullif(left(trim(p_note), 300), ''), auth.uid());
  end if;
end;
$$;

-- Removes a record made by mistake; the log keeps what it was.
create function public.delete_attendance_record(p_record uuid, p_note text default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r attendance_records%rowtype;
begin
  select * into r from attendance_records where id = p_record for update;
  if r.id is null then
    raise exception 'not_found';
  end if;
  perform public.check_attendance_editor(r.person_id);
  insert into attendance_edits (workspace_id, person_id, record_id, day, field, old_at, new_at,
                                detail, edited_by)
  values (r.workspace_id, r.person_id, null, r.day, 'deleted', r.in_at, r.out_at,
          nullif(left(trim(p_note), 300), ''), auth.uid());
  delete from attendance_records where id = r.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Corrections
-- ---------------------------------------------------------------------------

-- The signed-in user asks to correct a day (the last 31 days).
create function public.request_attendance_fix(p_workspace uuid, p_day date, p_in timestamptz,
                                              p_out timestamptz, p_note text)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  st     attendance_settings%rowtype;
  person uuid;
  today  date;
  f      uuid;
begin
  select * into st from attendance_settings where workspace_id = p_workspace;
  if st.workspace_id is null or not st.enabled then
    raise exception 'attendance_off';
  end if;
  person := public.attendance_me(p_workspace);
  today := (now() at time zone st.timezone)::date;
  if p_day is null or p_day > today or p_day < today - 31 then
    raise exception 'invalid_day';
  end if;
  if p_in is null and p_out is null then
    raise exception 'invalid_hours';
  end if;
  if p_in > now() + interval '1 minute' or p_out > now() + interval '1 minute' then
    raise exception 'future_time';
  end if;
  if p_out <= p_in then
    raise exception 'invalid_hours';
  end if;
  if length(trim(coalesce(p_note, ''))) = 0 then
    raise exception 'fix_note_required';
  end if;
  if exists (select 1 from attendance_fixes where person_id = person and day = p_day
             and status = 'pending') then
    raise exception 'fix_pending';
  end if;
  insert into attendance_fixes (workspace_id, person_id, day, in_at, out_at, note)
  values (p_workspace, person, p_day, p_in, p_out, left(trim(p_note), 300))
  returning id into f;
  perform public.queue_push(public.attendance_managers_of(person), p_workspace, 'attendance_fix',
    (select name from workspaces where id = p_workspace),
    public.attendance_person_name(person), p_day::text,
    jsonb_build_object('type', 'attendance_team'));
  return f;
end;
$$;

create function public.cancel_attendance_fix(p_fix uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update attendance_fixes f set status = 'cancelled'
  where f.id = p_fix and f.status = 'pending'
    and exists (select 1 from attendance_people ap where ap.id = f.person_id and ap.user_id = auth.uid());
  if not found then
    raise exception 'not_found';
  end if;
end;
$$;

create function public.decide_attendance_fix(p_fix uuid, p_accept boolean, p_note text default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  f    attendance_fixes%rowtype;
  r    attendance_records%rowtype;
  late record;
begin
  select * into f from attendance_fixes where id = p_fix for update;
  if f.id is null then
    raise exception 'not_found';
  end if;
  perform public.check_attendance_editor(f.person_id);
  if f.status <> 'pending' then
    raise exception 'already_reviewed';
  end if;

  if p_accept then
    select * into r from attendance_records where person_id = f.person_id and day = f.day for update;
    if r.id is null then
      if f.in_at is null then
        raise exception 'fix_needs_check_in';
      end if;
      select * into late from public.attendance_lateness(f.person_id, f.day, f.in_at);
      insert into attendance_records (workspace_id, person_id, day, shift_start, late_minutes,
                                      in_at, out_at, in_by, out_by)
      values (f.workspace_id, f.person_id, f.day, late.shift_start, late.late, f.in_at, f.out_at,
              auth.uid(), case when f.out_at is not null then auth.uid() end)
      returning * into r;
      insert into attendance_edits (workspace_id, person_id, record_id, day, field, new_at,
                                    detail, edited_by)
      values (f.workspace_id, f.person_id, r.id, f.day, 'in', f.in_at, f.note, auth.uid());
      if f.out_at is not null then
        insert into attendance_edits (workspace_id, person_id, record_id, day, field, new_at,
                                      detail, edited_by)
        values (f.workspace_id, f.person_id, r.id, f.day, 'out', f.out_at, f.note, auth.uid());
      end if;
    else
      perform public.apply_attendance_times(r, coalesce(f.in_at, r.in_at),
                                            coalesce(f.out_at, r.out_at), f.note);
    end if;
  end if;

  update attendance_fixes
  set status = case when p_accept then 'accepted' else 'rejected' end,
      decided_by = auth.uid(), decided_at = now(),
      decision_note = nullif(left(trim(p_note), 300), '')
  where id = f.id;
  perform public.queue_push(
    array[(select user_id from attendance_people where id = f.person_id)], f.workspace_id,
    case when p_accept then 'attendance_fix_accepted' else 'attendance_fix_rejected' end,
    (select name from workspaces where id = f.workspace_id),
    (select full_name from profiles where id = auth.uid()), f.day::text,
    jsonb_build_object('type', 'attendance'));
end;
$$;

-- The signed-in user's corrections between two days.
create function public.my_attendance_fixes(p_workspace uuid, p_from date, p_to date)
returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', f.id, 'day', f.day, 'in_at', f.in_at, 'out_at', f.out_at, 'note', f.note,
           'status', f.status, 'decision_note', f.decision_note,
           'decided_by', (select full_name from profiles where id = f.decided_by))
         order by f.day desc, f.created_at desc), '[]')
  from attendance_fixes f
  join attendance_people ap on ap.id = f.person_id
  where ap.workspace_id = p_workspace and ap.user_id = auth.uid()
    and f.day between p_from and least(p_to, p_from + 400);
$$;

-- What waits on the signed-in manager: check-ins from outside and
-- corrections, oldest first.
create function public.attendance_requests(p_workspace uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_attendance_manager(p_workspace) then
    raise exception 'not_allowed';
  end if;
  return jsonb_build_object(
    'reviews', coalesce((select jsonb_agg(public.attendance_record_json(r)
                                          || jsonb_build_object('name', public.attendance_person_name(r.person_id))
                                          order by r.in_at)
                         from attendance_records r
                         join attendance_people ap on ap.id = r.person_id
                         where r.workspace_id = p_workspace and r.review = 'pending'
                           and public.can_manage_attendance(r.person_id)
                           and (ap.user_id is distinct from auth.uid()
                                or public.is_workspace_admin(p_workspace))), '[]'),
    'fixes', coalesce((select jsonb_agg(jsonb_build_object(
                         'id', f.id, 'person_id', f.person_id,
                         'name', public.attendance_person_name(f.person_id),
                         'day', f.day, 'in_at', f.in_at, 'out_at', f.out_at, 'note', f.note,
                         'status', f.status, 'created_at', f.created_at,
                         'record', (select public.attendance_record_json(r) from attendance_records r
                                    where r.person_id = f.person_id and r.day = f.day))
                       order by f.created_at)
                       from attendance_fixes f
                       join attendance_people ap on ap.id = f.person_id
                       where f.workspace_id = p_workspace and f.status = 'pending'
                         and public.can_manage_attendance(f.person_id)
                         and (ap.user_id is distinct from auth.uid()
                              or public.is_workspace_admin(p_workspace))), '[]'));
end;
$$;

-- ---------------------------------------------------------------------------
-- The screen for everyone: also says whether the user manages others.
-- ---------------------------------------------------------------------------

create or replace function public.attendance_today(p_workspace uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  me     uuid := auth.uid();
  st     attendance_settings%rowtype;
  person uuid;
  shift  uuid;
  today  date;
  hours  record;
  open_r attendance_records%rowtype;
begin
  if not public.is_workspace_member(p_workspace) then
    raise exception 'not_allowed';
  end if;
  select * into st from attendance_settings where workspace_id = p_workspace;
  if st.workspace_id is null or not st.enabled then
    return jsonb_build_object('enabled', false,
                              'is_admin', public.is_workspace_admin(p_workspace));
  end if;
  today := (now() at time zone st.timezone)::date;
  select id into person from attendance_people where workspace_id = p_workspace and user_id = me;
  shift := case when person is not null then public.attendance_shift_of(person)
                else coalesce(st.default_shift_id,
                              (select id from attendance_shifts where workspace_id = p_workspace
                               order by created_at, id limit 1)) end;
  select * into hours from public.attendance_hours(p_workspace, shift, today);

  -- An open check-in from the last 20 hours (a night shift crosses midnight),
  -- else today's record.
  select * into open_r from attendance_records
  where person_id = person and out_at is null and in_at > now() - interval '20 hours'
  order by in_at desc limit 1;
  if open_r.id is null then
    select * into open_r from attendance_records where person_id = person and day = today;
  end if;

  return jsonb_build_object(
    'enabled', true,
    'is_admin', public.is_workspace_admin(p_workspace),
    'is_manager', public.is_attendance_manager(p_workspace),
    'timezone', st.timezone,
    'today', today,
    'weekend_days', to_jsonb(st.weekend_days),
    'require_selfie', st.require_selfie,
    'allow_outside', st.allow_outside,
    'shift', (select jsonb_build_object('name', sh.name, 'start_at', hours.start_at,
                                         'end_at', hours.end_at, 'grace', hours.grace)
              from attendance_shifts sh where sh.id = shift),
    'site', (select jsonb_build_object('id', s.id, 'name', s.name, 'lat', s.lat, 'lng', s.lng,
                                        'radius_m', s.radius_m)
             from attendance_people ap join attendance_sites s on s.id = ap.site_id
             where ap.id = person),
    'sites', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'lat', s.lat,
                                                            'lng', s.lng, 'radius_m', s.radius_m)
                                         order by s.name)
                       from attendance_sites s where s.workspace_id = p_workspace), '[]'),
    'record', case when open_r.id is not null then public.attendance_record_json(open_r) end,
    'recent', coalesce((select jsonb_agg(public.attendance_record_json(r) order by r.day desc)
                        from attendance_records r
                        where r.person_id = person and r.day between today - 6 and today), '[]'),
    'month', (select jsonb_build_object(
                'present', count(*),
                'late', count(*) filter (where r.late_minutes > 0),
                'late_minutes', coalesce(sum(r.late_minutes), 0))
              from attendance_records r
              where r.person_id = person and r.review <> 'rejected'
                and r.day >= date_trunc('month', today)::date and r.day <= today));
end;
$$;

-- Managers hear about check-ins from outside.
create function public.push_attendance_review()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.review = 'pending' then
    perform public.queue_push(public.attendance_managers_of(new.person_id), new.workspace_id,
      'attendance_review', (select name from workspaces where id = new.workspace_id),
      public.attendance_person_name(new.person_id), new.reason_note,
      jsonb_build_object('type', 'attendance_team'));
  end if;
  return null;
end;
$$;

create trigger attendance_records_review_push after insert on public.attendance_records
  for each row execute function public.push_attendance_review();

-- ---------------------------------------------------------------------------
-- Reminders (every 5 minutes)
-- ---------------------------------------------------------------------------

create function public.process_attendance_reminders()
returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  p     record;
  hours record;
  n     integer := 0;
begin
  for p in
    select ap.id, ap.user_id, ap.workspace_id, st.timezone, st.weekend_days,
           (now() at time zone st.timezone)::date as today, w.name as ws_name
    from attendance_people ap
    join attendance_settings st on st.workspace_id = ap.workspace_id
    join workspaces w on w.id = ap.workspace_id and w.deleted_at is null
    join workspace_members wm on wm.workspace_id = ap.workspace_id and wm.user_id = ap.user_id
                              and wm.status = 'active'
    where st.enabled and st.reminders and ap.active and ap.user_id is not null
  loop
    if extract(dow from p.today)::smallint = any (p.weekend_days) then
      continue;
    end if;
    select * into hours from public.attendance_hours(p.workspace_id, public.attendance_shift_of(p.id), p.today);
    if hours.start_at is null then
      continue;
    end if;
    -- Not in yet, a little after the grace ends.
    if now() between hours.start_at + make_interval(mins => hours.grace + 5)
                 and hours.start_at + interval '3 hours'
       and not exists (select 1 from attendance_records r where r.person_id = p.id
                       and (r.day = p.today or r.in_at > now() - interval '20 hours'))
       and not exists (select 1 from attendance_reminders_sent s
                       where s.person_id = p.id and s.day = p.today and s.kind = 'in') then
      insert into attendance_reminders_sent (person_id, day, kind) values (p.id, p.today, 'in');
      perform public.queue_push(array[p.user_id], p.workspace_id, 'attendance_in', p.ws_name,
                                null, null, jsonb_build_object('type', 'attendance'));
      n := n + 1;
    end if;
    -- Still in, half an hour after the shift ends.
    if now() between hours.end_at + interval '30 minutes' and hours.end_at + interval '4 hours'
       and exists (select 1 from attendance_records r where r.person_id = p.id
                   and r.out_at is null and r.in_at > now() - interval '20 hours')
       and not exists (select 1 from attendance_reminders_sent s
                       where s.person_id = p.id and s.day = p.today and s.kind = 'out') then
      insert into attendance_reminders_sent (person_id, day, kind) values (p.id, p.today, 'out');
      perform public.queue_push(array[p.user_id], p.workspace_id, 'attendance_out', p.ws_name,
                                null, null, jsonb_build_object('type', 'attendance'));
      n := n + 1;
    end if;
  end loop;
  delete from attendance_reminders_sent where day < current_date - 7;
  return n;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('wasla-attendance-reminders', '*/5 * * * *',
                          'select public.process_attendance_reminders()');
  else
    raise notice 'pg_cron is not available here; attendance reminders are not scheduled';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Billing: free workers per plan, extra workers on the invoice
-- ---------------------------------------------------------------------------

drop function public.admin_plans();
create function public.admin_plans()
returns table (id text, name text, max_members integer, storage_gb integer, price_usd numeric,
               offered boolean, workspaces integer, free_workers integer,
               extra_worker_usd numeric)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public.require_platform_admin();
  return query
  select p.id, p.name, p.max_members, p.storage_gb, p.price_usd_month, p.offered,
         (select count(*)::integer from workspaces w where w.plan_id = p.id),
         p.free_workers, p.extra_worker_usd
  from plans p
  order by p.sort, p.price_usd_month;
end;
$$;

-- p_free null = twice the plan's seats.
create function public.admin_set_plan_workers(p_plan text, p_free integer, p_extra_usd numeric)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.require_platform_admin();
  if p_free < 0 or coalesce(p_extra_usd, 0) < 0 or p_extra_usd > 10000 then
    raise exception 'invalid_price';
  end if;
  update plans set free_workers = p_free, extra_worker_usd = round(coalesce(p_extra_usd, 0), 2)
  where id = p_plan;
  if not found then
    raise exception 'not_found';
  end if;
end;
$$;

create or replace function public.admin_create_invoice(
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
  used     integer;
  free     integer;
  extra    integer;
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
    -- Workers without the app past the plan's free number.
    select q.used into used from public.attendance_worker_quota(ws.id) q;
    free := case when pl.max_members is null and pl.free_workers is null then null
                 else coalesce(pl.free_workers, pl.max_members * 2) end;
    extra := case when pl.extra_worker_usd > 0 and free is not null
                  then greatest(used - free, 0) else 0 end;
    insert into invoice_lines (invoice_id, workspace_id, workspace_name, plan_id, plan_name,
                               members, unit_usd, amount_usd, amount_local,
                               extra_workers, extra_worker_usd)
    values (inv, ws.id, ws.name, pl.id, pl.name, public.active_members(ws.id), unit,
            (unit + extra * pl.extra_worker_usd) * p_months,
            round((unit + extra * pl.extra_worker_usd) * p_months * v_rate, 2),
            extra, pl.extra_worker_usd);
    subtotal := subtotal + (unit + extra * pl.extra_worker_usd) * p_months;
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

create or replace function public.invoice_json(p_invoice uuid)
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
               'amount_local', l.amount_local, 'extra_workers', l.extra_workers,
               'extra_worker_usd', l.extra_worker_usd) order by l.workspace_name)
      from invoice_lines l where l.invoice_id = i.id), '[]'::jsonb))
  from invoices i join companies c on c.id = i.company_id
  where i.id = p_invoice;
$$;

-- ---------------------------------------------------------------------------
-- Function privileges
-- ---------------------------------------------------------------------------

revoke execute on function
  public.is_attendance_manager(uuid),
  public.check_attendance_editor(uuid),
  public.attendance_lateness(uuid, date, timestamptz),
  public.attendance_managers_of(uuid),
  public.attendance_person_name(uuid),
  public.attendance_worker_quota(uuid),
  public.attendance_sync_people(uuid),
  public.attendance_person_json(uuid, date),
  public.attendance_board(uuid, date, uuid),
  public.attendance_person_day(uuid, date),
  public.review_attendance(uuid, boolean),
  public.save_attendance_worker(uuid, uuid, text, text, text, text, uuid, uuid, uuid, text),
  public.remove_attendance_worker(uuid),
  public.assign_attendance(uuid, uuid, uuid),
  public.attendance_roll_call(uuid, text, jsonb, double precision, double precision, integer, text),
  public.set_attendance_times(uuid, timestamptz, timestamptz, text),
  public.apply_attendance_times(public.attendance_records, timestamptz, timestamptz, text),
  public.delete_attendance_record(uuid, text),
  public.request_attendance_fix(uuid, date, timestamptz, timestamptz, text),
  public.cancel_attendance_fix(uuid),
  public.decide_attendance_fix(uuid, boolean, text),
  public.my_attendance_fixes(uuid, date, date),
  public.attendance_requests(uuid),
  public.attendance_today(uuid),
  public.push_attendance_review(),
  public.process_attendance_reminders(),
  public.admin_plans(),
  public.admin_set_plan_workers(text, integer, numeric),
  public.admin_create_invoice(uuid, jsonb, integer, numeric, text, integer),
  public.invoice_json(uuid)
from public, anon, authenticated;

grant execute on function
  public.attendance_board(uuid, date, uuid),
  public.attendance_person_day(uuid, date),
  public.review_attendance(uuid, boolean),
  public.save_attendance_worker(uuid, uuid, text, text, text, text, uuid, uuid, uuid, text),
  public.remove_attendance_worker(uuid),
  public.assign_attendance(uuid, uuid, uuid),
  public.attendance_roll_call(uuid, text, jsonb, double precision, double precision, integer, text),
  public.set_attendance_times(uuid, timestamptz, timestamptz, text),
  public.delete_attendance_record(uuid, text),
  public.request_attendance_fix(uuid, date, timestamptz, timestamptz, text),
  public.cancel_attendance_fix(uuid),
  public.decide_attendance_fix(uuid, boolean, text),
  public.my_attendance_fixes(uuid, date, date),
  public.attendance_requests(uuid),
  public.attendance_today(uuid),
  public.admin_plans(),
  public.admin_set_plan_workers(text, integer, numeric),
  public.admin_create_invoice(uuid, jsonb, integer, numeric, text, integer)
to authenticated;
