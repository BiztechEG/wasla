-- Attendance: checking in and out.
--
-- * A workspace admin turns attendance on, then sets branches (a point and a
--   radius, or a "field" branch with no fixed place), shifts (start, end and
--   minutes of grace), the weekly days off, Ramadan hours, and whether a
--   selfie is needed.
-- * People check in and out from their phone. The server measures how far
--   they are from their branch. Checking in from outside needs a reason and
--   goes to a manager to review.
-- * Being late is measured from the shift's start; within the grace minutes
--   it does not count. Days off never count as late.
-- * Everyone who checks in gets a row in attendance_people. People without
--   the app (added by a manager) get one too; managers record them (next
--   migration).
-- * Who sees a person's attendance: the person, workspace owners and admins,
--   and the leads of the projects the person works in.
-- * Selfies are uploads in the "files" bucket. They are kept 90 days.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.attendance_shifts (
  id            uuid primary key default gen_random_uuid(),
  workspace_id  uuid not null references public.workspaces (id) on delete cascade,
  name          text not null check (length(trim(name)) between 1 and 60),
  start_time    time not null,
  end_time      time not null,
  grace_minutes integer not null default 15 check (grace_minutes between 0 and 180),
  created_at    timestamptz not null default now()
);

create index attendance_shifts_workspace_idx on public.attendance_shifts (workspace_id);

create table public.attendance_sites (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  name         text not null check (length(trim(name)) between 1 and 80),
  -- No point: a field branch, where any place is fine and is only recorded.
  lat          double precision check (lat between -90 and 90),
  lng          double precision check (lng between -180 and 180),
  radius_m     integer not null default 150 check (radius_m between 20 and 5000),
  created_at   timestamptz not null default now(),
  check ((lat is null) = (lng is null))
);

create index attendance_sites_workspace_idx on public.attendance_sites (workspace_id);

create table public.attendance_settings (
  workspace_id     uuid primary key references public.workspaces (id) on delete cascade,
  enabled          boolean not null default true,
  timezone         text not null default 'Africa/Cairo',
  -- Days off, 0 = Sunday ... 6 = Saturday.
  weekend_days     smallint[] not null default '{5,6}'
                   check (weekend_days <@ '{0,1,2,3,4,5,6}'::smallint[]),
  require_selfie   boolean not null default false,
  allow_outside    boolean not null default true,
  reminders        boolean not null default true,
  default_shift_id uuid references public.attendance_shifts (id) on delete set null,
  -- Ramadan hours replace every shift's hours between these days.
  ramadan_from     date,
  ramadan_to       date,
  ramadan_start    time,
  ramadan_end      time,
  updated_at       timestamptz not null default now(),
  check ((ramadan_from is null) = (ramadan_to is null)
         and (ramadan_from is null) = (ramadan_start is null)
         and (ramadan_from is null) = (ramadan_end is null)
         and (ramadan_from is null or ramadan_to >= ramadan_from))
);

-- Everyone whose attendance is kept: app users (user_id) and people without
-- the app (full_name), who belong to a project whose leads record them.
create table public.attendance_people (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  user_id      uuid references public.profiles (id) on delete cascade,
  full_name    text check (length(trim(full_name)) between 1 and 100),
  job_title    text check (length(job_title) <= 60),
  phone        text check (length(phone) <= 30),
  code         text check (length(code) <= 30),
  photo_path   text,
  project_id   uuid references public.projects (id) on delete set null,
  site_id      uuid references public.attendance_sites (id) on delete set null,
  shift_id     uuid references public.attendance_shifts (id) on delete set null,
  active       boolean not null default true,
  created_by   uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  unique (workspace_id, user_id),
  check (user_id is not null or full_name is not null)
);

create index attendance_people_project_idx on public.attendance_people (project_id);

create table public.attendance_records (
  id              uuid primary key default gen_random_uuid(),
  workspace_id    uuid not null references public.workspaces (id) on delete cascade,
  person_id       uuid not null references public.attendance_people (id) on delete cascade,
  -- The local day the shift started on.
  day             date not null,
  shift_start     timestamptz,
  late_minutes    integer not null default 0,
  in_at           timestamptz not null,
  in_lat          double precision,
  in_lng          double precision,
  in_accuracy_m   integer,
  in_site_id      uuid references public.attendance_sites (id) on delete set null,
  in_distance_m   integer,
  in_photo_path   text,
  out_at          timestamptz,
  out_lat         double precision,
  out_lng         double precision,
  out_site_id     uuid references public.attendance_sites (id) on delete set null,
  out_distance_m  integer,
  out_photo_path  text,
  outside         boolean not null default false,
  reason_kind     text check (reason_kind in ('client', 'field', 'home', 'other')),
  reason_note     text check (length(reason_note) <= 300),
  -- 'pending' while a manager has not looked at a check-in from outside.
  review          text not null default 'none'
                  check (review in ('none', 'pending', 'accepted', 'rejected')),
  reviewed_by     uuid references public.profiles (id) on delete set null,
  reviewed_at     timestamptz,
  in_by           uuid references public.profiles (id) on delete set null,
  out_by          uuid references public.profiles (id) on delete set null,
  created_at      timestamptz not null default now(),
  unique (person_id, day),
  check (out_at is null or out_at >= in_at)
);

create index attendance_records_workspace_day_idx on public.attendance_records (workspace_id, day);
create index attendance_records_open_idx on public.attendance_records (person_id) where out_at is null;
create index attendance_records_in_photo_idx on public.attendance_records (in_photo_path)
  where in_photo_path is not null;
create index attendance_records_out_photo_idx on public.attendance_records (out_photo_path)
  where out_photo_path is not null;

alter table public.attendance_shifts   enable row level security;
alter table public.attendance_sites    enable row level security;
alter table public.attendance_settings enable row level security;
alter table public.attendance_people   enable row level security;
alter table public.attendance_records  enable row level security;
revoke all on public.attendance_shifts, public.attendance_sites, public.attendance_settings,
              public.attendance_people, public.attendance_records
  from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- The time zone a company's country uses.
create function public.country_timezone(p_country text)
returns text
language sql immutable set search_path = public, pg_temp as $$
  select case upper(p_country)
    when 'SA' then 'Asia/Riyadh'
    when 'AE' then 'Asia/Dubai'
    when 'KW' then 'Asia/Kuwait'
    when 'QA' then 'Asia/Qatar'
    when 'BH' then 'Asia/Bahrain'
    when 'OM' then 'Asia/Muscat'
    when 'JO' then 'Asia/Amman'
    else 'Africa/Cairo' end;
$$;

-- Metres between two points (haversine).
create function public.geo_distance(lat1 double precision, lng1 double precision,
                                    lat2 double precision, lng2 double precision)
returns double precision
language sql immutable set search_path = public, pg_temp as $$
  select 2 * 6371000 * asin(least(1, sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2))));
$$;

-- Whether the signed-in user may see and record a person's attendance:
-- workspace owners and admins, and leads of a project the person is in (for
-- people without the app, the project they were added to).
create function public.can_manage_attendance(p_person uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from attendance_people ap
    where ap.id = p_person
      and (public.is_workspace_admin(ap.workspace_id)
           or (ap.project_id is not null and ap.project_id in (select public.my_managed_project_ids()))
           or (ap.user_id is not null and exists (
                 select 1 from project_members pm
                 join projects pr on pr.id = pm.project_id
                 where pm.user_id = ap.user_id and pr.workspace_id = ap.workspace_id
                   and pr.status = 'active'
                   and pm.project_id in (select public.my_managed_project_ids()))))
  );
$$;

create function public.can_see_attendance(p_person uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from attendance_people ap
    where ap.id = p_person and ap.user_id = auth.uid()
      and public.is_workspace_member(ap.workspace_id)
  ) or public.can_manage_attendance(p_person);
$$;

-- A shift's hours on a day, with Ramadan hours when they apply.
create function public.attendance_hours(p_workspace uuid, p_shift uuid, p_day date,
                                        out start_at timestamptz, out end_at timestamptz,
                                        out grace integer)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  st  attendance_settings%rowtype;
  sh  attendance_shifts%rowtype;
  s   time;
  e   time;
begin
  select * into st from attendance_settings where workspace_id = p_workspace;
  select * into sh from attendance_shifts where id = p_shift and workspace_id = p_workspace;
  if sh.id is null then
    return;
  end if;
  s := sh.start_time;
  e := sh.end_time;
  if st.ramadan_from is not null and p_day between st.ramadan_from and st.ramadan_to then
    s := st.ramadan_start;
    e := st.ramadan_end;
  end if;
  start_at := (p_day + s) at time zone coalesce(st.timezone, 'Africa/Cairo');
  -- A shift that ends after midnight ends the next day.
  end_at := ((p_day + (e <= s)::integer) + e) at time zone coalesce(st.timezone, 'Africa/Cairo');
  grace := sh.grace_minutes;
end;
$$;

-- The shift a person works: their own, else the workspace's default, else
-- the first one made.
create function public.attendance_shift_of(p_person uuid)
returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(
    (select sh.id from attendance_people ap
     join attendance_shifts sh on sh.id = ap.shift_id where ap.id = p_person),
    (select st.default_shift_id from attendance_people ap
     join attendance_settings st on st.workspace_id = ap.workspace_id where ap.id = p_person),
    (select sh.id from attendance_people ap
     join attendance_shifts sh on sh.workspace_id = ap.workspace_id
     where ap.id = p_person order by sh.created_at, sh.id limit 1));
$$;

-- Where a check-in at (lat, lng) is: the person's branch, else the nearest
-- branch that has a point. inside is true within the radius (allowing for
-- up to 50 m of GPS error), at a field branch, or when no branch is set.
create function public.attendance_place(p_person uuid, p_lat double precision,
                                        p_lng double precision, p_accuracy integer,
                                        out site_id uuid, out distance_m integer,
                                        out inside boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  ap    attendance_people%rowtype;
  s     attendance_sites%rowtype;
  slack double precision := least(greatest(coalesce(p_accuracy, 0), 0), 50);
begin
  select * into ap from attendance_people where id = p_person;
  if ap.site_id is not null then
    select * into s from attendance_sites where id = ap.site_id;
  else
    select * into s from attendance_sites
    where workspace_id = ap.workspace_id and lat is not null
    order by public.geo_distance(lat, lng, p_lat, p_lng)
    limit 1;
  end if;
  if s.id is null then
    inside := true;
    return;
  end if;
  site_id := s.id;
  if s.lat is null then
    inside := true;
    return;
  end if;
  distance_m := round(public.geo_distance(s.lat, s.lng, p_lat, p_lng));
  inside := distance_m - slack <= s.radius_m;
end;
$$;

-- The signed-in user's attendance row in a workspace, made on first use.
create function public.attendance_me(p_workspace uuid)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me uuid := auth.uid();
  p  uuid;
begin
  if not public.is_workspace_member(p_workspace) then
    raise exception 'not_allowed';
  end if;
  select id into p from attendance_people where workspace_id = p_workspace and user_id = me;
  if p is null then
    insert into attendance_people (workspace_id, user_id, created_by)
    values (p_workspace, me, me)
    on conflict (workspace_id, user_id) do nothing
    returning id into p;
    if p is null then
      select id into p from attendance_people where workspace_id = p_workspace and user_id = me;
    end if;
  end if;
  return p;
end;
$$;

-- A record as the app reads it.
create function public.attendance_record_json(r attendance_records)
returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'id', r.id,
    'person_id', r.person_id,
    'day', r.day,
    'shift_start', r.shift_start,
    'late_minutes', r.late_minutes,
    'in_at', r.in_at,
    'out_at', r.out_at,
    'in_site', (select name from attendance_sites where id = r.in_site_id),
    'in_distance_m', r.in_distance_m,
    'out_site', (select name from attendance_sites where id = r.out_site_id),
    'out_distance_m', r.out_distance_m,
    'in_photo_path', case when r.in_at > now() - interval '90 days' then r.in_photo_path end,
    'out_photo_path', case when r.in_at > now() - interval '90 days' then r.out_photo_path end,
    'in_lat', r.in_lat,
    'in_lng', r.in_lng,
    'outside', r.outside,
    'reason_kind', r.reason_kind,
    'reason_note', r.reason_note,
    'review', r.review,
    'in_by', r.in_by,
    'in_by_name', (select full_name from profiles where id = r.in_by),
    'out_by_name', (select full_name from profiles where id = r.out_by));
$$;

-- A selfie must be one's own upload in the workspace, already stored.
create function public.check_attendance_photo(p_workspace uuid, p_path text)
returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if p_path is null then
    return;
  end if;
  if split_part(p_path, '/', 1) <> p_workspace::text
     or not public.can_upload_object(p_path)
     or not exists (select 1 from storage.objects o where o.bucket_id = 'files' and o.name = p_path)
     or exists (select 1 from files where storage_path = p_path) then
    raise exception 'invalid_file';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Checking in and out
-- ---------------------------------------------------------------------------

-- Everything the attendance screen shows, for the signed-in user.
create function public.attendance_today(p_workspace uuid)
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

create function public.attendance_check_in(
  p_workspace   uuid,
  p_lat         double precision,
  p_lng         double precision,
  p_accuracy    integer default null,
  p_photo       text    default null,
  p_reason_kind text    default null,
  p_reason_note text    default null
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me     uuid := auth.uid();
  st     attendance_settings%rowtype;
  person uuid;
  today  date;
  place  record;
  hours  record;
  late   integer := 0;
  r      attendance_records%rowtype;
begin
  select * into st from attendance_settings where workspace_id = p_workspace;
  if st.workspace_id is null or not st.enabled then
    raise exception 'attendance_off';
  end if;
  person := public.attendance_me(p_workspace);
  perform 1 from attendance_people where id = person for update;

  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'location_required';
  end if;
  today := (now() at time zone st.timezone)::date;
  if exists (select 1 from attendance_records
             where person_id = person
               and (day = today or (out_at is null and in_at > now() - interval '20 hours'))) then
    raise exception 'already_checked_in';
  end if;

  if st.require_selfie and p_photo is null then
    raise exception 'selfie_required';
  end if;
  perform public.check_attendance_photo(p_workspace, p_photo);

  select * into place from public.attendance_place(person, p_lat, p_lng, p_accuracy);
  if not place.inside then
    if not st.allow_outside then
      raise exception 'outside_not_allowed';
    end if;
    if p_reason_kind is null or p_reason_kind not in ('client', 'field', 'home', 'other') then
      raise exception 'attendance_reason_required';
    end if;
  end if;

  select * into hours from public.attendance_hours(p_workspace, public.attendance_shift_of(person), today);
  if hours.start_at is not null
     and not (extract(dow from today)::smallint = any (st.weekend_days))
     and now() > hours.start_at + make_interval(mins => hours.grace) then
    late := floor(extract(epoch from now() - hours.start_at) / 60);
  end if;

  insert into attendance_records (workspace_id, person_id, day, shift_start, late_minutes,
                                  in_at, in_lat, in_lng, in_accuracy_m, in_site_id, in_distance_m,
                                  in_photo_path, outside, reason_kind, reason_note, review, in_by)
  values (p_workspace, person, today, hours.start_at, late,
          now(), p_lat, p_lng, p_accuracy, place.site_id, place.distance_m,
          p_photo, not place.inside,
          case when not place.inside then p_reason_kind end,
          case when not place.inside then nullif(left(trim(p_reason_note), 300), '') end,
          case when place.inside then 'none' else 'pending' end, me)
  returning * into r;
  return public.attendance_record_json(r);
end;
$$;

create function public.attendance_check_out(
  p_workspace uuid,
  p_lat       double precision,
  p_lng       double precision,
  p_accuracy  integer default null,
  p_photo     text    default null
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  st     attendance_settings%rowtype;
  person uuid;
  place  record;
  r      attendance_records%rowtype;
begin
  select * into st from attendance_settings where workspace_id = p_workspace;
  if st.workspace_id is null or not st.enabled then
    raise exception 'attendance_off';
  end if;
  person := public.attendance_me(p_workspace);
  select * into r from attendance_records
  where person_id = person and out_at is null and in_at > now() - interval '20 hours'
  order by in_at desc limit 1
  for update;
  if r.id is null then
    raise exception 'not_checked_in';
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'location_required';
  end if;
  perform public.check_attendance_photo(p_workspace, p_photo);
  select * into place from public.attendance_place(person, p_lat, p_lng, p_accuracy);

  update attendance_records
  set out_at = now(), out_lat = p_lat, out_lng = p_lng, out_site_id = place.site_id,
      out_distance_m = place.distance_m, out_photo_path = p_photo, out_by = auth.uid()
  where id = r.id
  returning * into r;
  return public.attendance_record_json(r);
end;
$$;

-- The signed-in user's records between two days, newest first.
create function public.my_attendance(p_workspace uuid, p_from date, p_to date)
returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(public.attendance_record_json(r) order by r.day desc), '[]')
  from attendance_records r
  join attendance_people ap on ap.id = r.person_id
  where ap.workspace_id = p_workspace and ap.user_id = auth.uid()
    and public.is_workspace_member(p_workspace)
    and r.day between p_from and least(p_to, p_from + 400);
$$;

-- ---------------------------------------------------------------------------
-- Setting it up (workspace owners and admins)
-- ---------------------------------------------------------------------------

create function public.check_attendance_admin(p_workspace uuid)
returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_workspace_admin(p_workspace) then
    raise exception 'not_allowed';
  end if;
end;
$$;

-- Turns attendance on, with a first shift named p_shift_name (9 to 5) the
-- first time.
create function public.enable_attendance(p_workspace uuid, p_shift_name text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  sh uuid;
begin
  perform public.check_attendance_admin(p_workspace);
  if exists (select 1 from attendance_settings where workspace_id = p_workspace) then
    update attendance_settings set enabled = true, updated_at = now() where workspace_id = p_workspace;
    return;
  end if;
  insert into attendance_settings (workspace_id, timezone)
  select p_workspace, public.country_timezone(c.country_code)
  from workspaces w join companies c on c.id = w.company_id where w.id = p_workspace;
  insert into attendance_shifts (workspace_id, name, start_time, end_time)
  values (p_workspace, coalesce(nullif(trim(p_shift_name), ''), 'Shift'), '09:00', '17:00')
  returning id into sh;
  update attendance_settings set default_shift_id = sh where workspace_id = p_workspace;
end;
$$;

-- Settings, shifts and branches, for the setup screen.
create function public.attendance_setup(p_workspace uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  st attendance_settings%rowtype;
begin
  perform public.check_attendance_admin(p_workspace);
  select * into st from attendance_settings where workspace_id = p_workspace;
  if st.workspace_id is null then
    return jsonb_build_object('enabled', false, 'shifts', '[]'::jsonb, 'sites', '[]'::jsonb);
  end if;
  return jsonb_build_object(
    'enabled', st.enabled,
    'timezone', st.timezone,
    'weekend_days', to_jsonb(st.weekend_days),
    'require_selfie', st.require_selfie,
    'allow_outside', st.allow_outside,
    'reminders', st.reminders,
    'default_shift_id', st.default_shift_id,
    'ramadan_from', st.ramadan_from,
    'ramadan_to', st.ramadan_to,
    'ramadan_start', st.ramadan_start,
    'ramadan_end', st.ramadan_end,
    'shifts', coalesce((select jsonb_agg(jsonb_build_object(
                 'id', sh.id, 'name', sh.name, 'start_time', sh.start_time,
                 'end_time', sh.end_time, 'grace_minutes', sh.grace_minutes,
                 'people', (select count(*) from attendance_people ap
                            where ap.shift_id = sh.id and ap.active))
               order by sh.created_at, sh.id)
               from attendance_shifts sh where sh.workspace_id = p_workspace), '[]'),
    'sites', coalesce((select jsonb_agg(jsonb_build_object(
                 'id', s.id, 'name', s.name, 'lat', s.lat, 'lng', s.lng, 'radius_m', s.radius_m,
                 'people', (select count(*) from attendance_people ap
                            where ap.site_id = s.id and ap.active))
               order by s.name)
               from attendance_sites s where s.workspace_id = p_workspace), '[]'));
end;
$$;

create function public.save_attendance_settings(
  p_workspace      uuid,
  p_enabled        boolean,
  p_weekend_days   smallint[],
  p_require_selfie boolean,
  p_allow_outside  boolean,
  p_reminders      boolean,
  p_default_shift  uuid,
  p_ramadan_from   date,
  p_ramadan_to     date,
  p_ramadan_start  time,
  p_ramadan_end    time,
  p_timezone       text default null
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.check_attendance_admin(p_workspace);
  if p_default_shift is not null
     and not exists (select 1 from attendance_shifts where id = p_default_shift and workspace_id = p_workspace) then
    raise exception 'not_found';
  end if;
  if p_timezone is not null and not exists (select 1 from pg_timezone_names where name = p_timezone) then
    raise exception 'invalid_timezone';
  end if;
  update attendance_settings
  set enabled = coalesce(p_enabled, enabled),
      weekend_days = coalesce(p_weekend_days, weekend_days),
      require_selfie = coalesce(p_require_selfie, require_selfie),
      allow_outside = coalesce(p_allow_outside, allow_outside),
      reminders = coalesce(p_reminders, reminders),
      default_shift_id = p_default_shift,
      ramadan_from = p_ramadan_from, ramadan_to = p_ramadan_to,
      ramadan_start = p_ramadan_start, ramadan_end = p_ramadan_end,
      timezone = coalesce(p_timezone, timezone),
      updated_at = now()
  where workspace_id = p_workspace;
  if not found then
    raise exception 'attendance_off';
  end if;
end;
$$;

-- Adds a shift (p_id null) or changes one. Returns its id.
create function public.save_attendance_shift(
  p_workspace uuid, p_id uuid, p_name text,
  p_start time, p_end time, p_grace integer
) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  sh uuid;
begin
  perform public.check_attendance_admin(p_workspace);
  if not exists (select 1 from attendance_settings where workspace_id = p_workspace) then
    raise exception 'attendance_off';
  end if;
  if p_start is null or p_end is null or p_start = p_end then
    raise exception 'invalid_hours';
  end if;
  if p_id is null then
    if (select count(*) from attendance_shifts where workspace_id = p_workspace) >= 50 then
      raise exception 'too_many';
    end if;
    insert into attendance_shifts (workspace_id, name, start_time, end_time, grace_minutes)
    values (p_workspace, trim(p_name), p_start, p_end, coalesce(p_grace, 15))
    returning id into sh;
  else
    update attendance_shifts
    set name = trim(p_name), start_time = p_start, end_time = p_end,
        grace_minutes = coalesce(p_grace, grace_minutes)
    where id = p_id and workspace_id = p_workspace
    returning id into sh;
    if sh is null then
      raise exception 'not_found';
    end if;
  end if;
  return sh;
end;
$$;

create function public.delete_attendance_shift(p_workspace uuid, p_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.check_attendance_admin(p_workspace);
  delete from attendance_shifts where id = p_id and workspace_id = p_workspace;
end;
$$;

-- Adds a branch (p_id null) or changes one; no point makes a field branch.
create function public.save_attendance_site(
  p_workspace uuid, p_id uuid, p_name text,
  p_lat double precision, p_lng double precision, p_radius integer
) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  s uuid;
begin
  perform public.check_attendance_admin(p_workspace);
  if not exists (select 1 from attendance_settings where workspace_id = p_workspace) then
    raise exception 'attendance_off';
  end if;
  if p_id is null then
    if (select count(*) from attendance_sites where workspace_id = p_workspace) >= 200 then
      raise exception 'too_many';
    end if;
    insert into attendance_sites (workspace_id, name, lat, lng, radius_m)
    values (p_workspace, trim(p_name), p_lat, p_lng, coalesce(p_radius, 150))
    returning id into s;
  else
    update attendance_sites
    set name = trim(p_name), lat = p_lat, lng = p_lng, radius_m = coalesce(p_radius, radius_m)
    where id = p_id and workspace_id = p_workspace
    returning id into s;
    if s is null then
      raise exception 'not_found';
    end if;
  end if;
  return s;
end;
$$;

create function public.delete_attendance_site(p_workspace uuid, p_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.check_attendance_admin(p_workspace);
  delete from attendance_sites where id = p_id and workspace_id = p_workspace;
end;
$$;

-- ---------------------------------------------------------------------------
-- Stored photos: readable by whoever sees the record, never removed by hand,
-- and cleaned up after 90 days.
-- ---------------------------------------------------------------------------

create function public.is_attendance_photo(p_name text)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from attendance_records where in_photo_path = p_name)
      or exists (select 1 from attendance_records where out_photo_path = p_name)
      or exists (select 1 from attendance_people where photo_path = p_name);
$$;

create or replace function public.can_read_object(p_name text)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from files fl
                 where fl.storage_path = p_name and public.can_see_file(fl.id))
      or public.can_upload_object(p_name)
      or exists (select 1 from attendance_records r
                 where (r.in_photo_path = p_name or r.out_photo_path = p_name)
                   and public.can_see_attendance(r.person_id))
      or exists (select 1 from attendance_people ap
                 where ap.photo_path = p_name and public.can_see_attendance(ap.id));
$$;

create or replace function public.can_remove_object(p_name text)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select split_part(p_name, '/', 2) = auth.uid()::text
     and not exists (select 1 from files where storage_path = p_name and deleted_at is null)
     and not public.is_attendance_photo(p_name);
$$;

create or replace function public.files_to_purge(p_key text, p_limit integer default 500)
returns table (path text)
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.check_edge_key(p_key);
  return query
  (select f.storage_path from files f
   where f.deleted_at < now() - interval '1 day' and f.purged_at is null
   union
   select o.name from storage.objects o
   where o.bucket_id = 'files' and o.created_at < now() - interval '1 day'
     and not exists (select 1 from files f where f.storage_path = o.name)
     and not exists (select 1 from attendance_people ap where ap.photo_path = o.name)
     and not exists (select 1 from attendance_records r
                     where (r.in_photo_path = o.name or r.out_photo_path = o.name)
                       and r.in_at > now() - interval '90 days'))
  limit least(greatest(p_limit, 1), 1000);
end;
$$;

-- ---------------------------------------------------------------------------
-- Function privileges
-- ---------------------------------------------------------------------------

revoke execute on function
  public.country_timezone(text),
  public.geo_distance(double precision, double precision, double precision, double precision),
  public.can_manage_attendance(uuid),
  public.can_see_attendance(uuid),
  public.attendance_hours(uuid, uuid, date),
  public.attendance_shift_of(uuid),
  public.attendance_place(uuid, double precision, double precision, integer),
  public.attendance_me(uuid),
  public.attendance_record_json(public.attendance_records),
  public.check_attendance_photo(uuid, text),
  public.attendance_today(uuid),
  public.attendance_check_in(uuid, double precision, double precision, integer, text, text, text),
  public.attendance_check_out(uuid, double precision, double precision, integer, text),
  public.my_attendance(uuid, date, date),
  public.check_attendance_admin(uuid),
  public.enable_attendance(uuid, text),
  public.attendance_setup(uuid),
  public.save_attendance_settings(uuid, boolean, smallint[], boolean, boolean, boolean, uuid,
                                  date, date, time, time, text),
  public.save_attendance_shift(uuid, uuid, text, time, time, integer),
  public.delete_attendance_shift(uuid, uuid),
  public.save_attendance_site(uuid, uuid, text, double precision, double precision, integer),
  public.delete_attendance_site(uuid, uuid),
  public.is_attendance_photo(text),
  public.can_read_object(text),
  public.can_remove_object(text),
  public.files_to_purge(text, integer)
from public, anon, authenticated;

grant execute on function
  public.can_manage_attendance(uuid),
  public.can_see_attendance(uuid),
  public.can_read_object(text),
  public.can_remove_object(text),
  public.attendance_today(uuid),
  public.attendance_check_in(uuid, double precision, double precision, integer, text, text, text),
  public.attendance_check_out(uuid, double precision, double precision, integer, text),
  public.my_attendance(uuid, date, date),
  public.enable_attendance(uuid, text),
  public.attendance_setup(uuid),
  public.save_attendance_settings(uuid, boolean, smallint[], boolean, boolean, boolean, uuid,
                                  date, date, time, time, text),
  public.save_attendance_shift(uuid, uuid, text, time, time, integer),
  public.delete_attendance_shift(uuid, uuid),
  public.save_attendance_site(uuid, uuid, text, double precision, double precision, integer),
  public.delete_attendance_site(uuid, uuid)
to authenticated;
