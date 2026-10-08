-- Phase 3: tasks, their updates and attachments, reminders, and in-app
-- notifications.
--
-- Every task belongs to a project. A public task is seen by everyone in the
-- project; a private one by its creator, the people it is assigned to, and
-- the project's leads and the workspace's admins. Those people are the
-- task's parties: only they see and write its comments, even on a public
-- task. Assignees move a task along; whoever created it (or a lead or admin)
-- marks it done or reopens it.
--
-- Reminders are rows in task_reminders that a pg_cron job turns into
-- notifications every minute. Push delivery of notifications comes later.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create type public.task_status     as enum ('new', 'in_progress', 'on_hold', 'review', 'done');
create type public.task_priority   as enum ('normal', 'high', 'urgent');
create type public.task_visibility as enum ('private', 'public');
create type public.task_event      as enum
  ('created', 'status', 'due', 'priority', 'title', 'visibility', 'assignees', 'attachment', 'comment');

create table public.tasks (
  id                uuid primary key default gen_random_uuid(),
  workspace_id      uuid not null references public.workspaces (id) on delete cascade,
  project_id        uuid not null references public.projects (id) on delete cascade,
  title             text not null check (length(trim(title)) > 0 and length(title) <= 200),
  description       text check (length(description) <= 4000),
  status            public.task_status not null default 'new',
  hold_reason       text check (length(hold_reason) <= 500),
  priority          public.task_priority not null default 'normal',
  visibility        public.task_visibility not null default 'private',
  due_at            timestamptz,
  -- Minutes before the due time to remind the assignees.
  remind_before     integer[] not null default '{1440,60}',
  source_message_id uuid references public.messages (id) on delete set null,
  created_by        uuid not null references public.profiles (id),
  created_at        timestamptz not null default clock_timestamp(),
  -- Last change of any kind, comments included, so the app can follow it.
  updated_at        timestamptz not null default clock_timestamp(),
  done_at           timestamptz,
  deleted_at        timestamptz
);

create index tasks_project_idx on public.tasks (project_id) where deleted_at is null;
create index tasks_creator_idx on public.tasks (created_by) where deleted_at is null;

create table public.task_assignees (
  task_id  uuid not null references public.tasks (id) on delete cascade,
  user_id  uuid not null references public.profiles (id) on delete cascade,
  added_at timestamptz not null default clock_timestamp(),
  primary key (task_id, user_id)
);

create index task_assignees_user_idx on public.task_assignees (user_id);

create table public.task_activity (
  id         uuid primary key default gen_random_uuid(),
  task_id    uuid not null references public.tasks (id) on delete cascade,
  actor_id   uuid not null references public.profiles (id),
  kind       public.task_event not null,
  old_value  text,
  new_value  text,
  body       text check (length(body) <= 2000),
  file_id    uuid references public.files (id),
  created_at timestamptz not null default clock_timestamp()
);

create index task_activity_task_idx  on public.task_activity (task_id, created_at);
create index task_activity_actor_idx on public.task_activity (actor_id, created_at desc);

-- before:  minutes before the due time, for the assignees.
-- overdue: at the due time, for the assignees and the creator.
-- custom:  a time the creator picked, for the assignees.
create table public.task_reminders (
  id         uuid primary key default gen_random_uuid(),
  task_id    uuid not null references public.tasks (id) on delete cascade,
  kind       text not null check (kind in ('before', 'overdue', 'custom')),
  remind_at  timestamptz not null,
  created_by uuid references public.profiles (id),
  sent_at    timestamptz
);

create index task_reminders_due_idx on public.task_reminders (remind_at) where sent_at is null;

create table public.notifications (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles (id) on delete cascade,
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  kind         text not null check (kind in ('assigned', 'status', 'comment', 'due_changed',
                                             'nudge', 'due_soon', 'overdue', 'reminder')),
  task_id      uuid references public.tasks (id) on delete cascade,
  actor_id     uuid references public.profiles (id),
  detail       text check (length(detail) <= 200),
  created_at   timestamptz not null default clock_timestamp(),
  read_at      timestamptz
);

create index notifications_user_idx on public.notifications (user_id, created_at desc);

-- A task's attachments are project files too.
alter table public.files add column task_id uuid references public.tasks (id) on delete cascade;
create index files_task_idx on public.files (task_id) where task_id is not null;

-- ---------------------------------------------------------------------------
-- Permission helpers
-- ---------------------------------------------------------------------------

-- Projects the signed-in user sees, in workspaces they are active in.
create function public.my_project_ids()
returns setof uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select pr.id
  from projects pr
  join workspace_members wm
    on wm.workspace_id = pr.workspace_id and wm.user_id = auth.uid() and wm.status = 'active'
  where wm.role in ('owner', 'admin')
     or exists (select 1 from project_members pm
                where pm.project_id = pr.id and pm.user_id = auth.uid());
$$;

create function public.is_task_assignee(t uuid, u uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from task_assignees where task_id = t and user_id = u);
$$;

-- Creator, assignees, and the project's leads and the workspace's admins.
create function public.is_task_party(t uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from tasks tk
    where tk.id = t and tk.deleted_at is null
      and public.can_see_project(tk.project_id)
      and (tk.created_by = auth.uid()
           or public.is_task_assignee(tk.id, auth.uid())
           or public.can_manage_project(tk.project_id))
  );
$$;

create function public.can_see_task(t uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from tasks tk
    where tk.id = t and tk.deleted_at is null
      and public.can_see_project(tk.project_id)
      and (tk.visibility = 'public' or public.is_task_party(tk.id))
  );
$$;

-- The creator, or a lead or admin, changes what a task is.
create function public.can_edit_task(t uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from tasks tk
    where tk.id = t and tk.deleted_at is null
      and public.can_see_project(tk.project_id)
      and (tk.created_by = auth.uid() or public.can_manage_project(tk.project_id))
  );
$$;

-- A task's attachments follow the task.
create or replace function public.can_see_file(f uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from files fl
    where fl.id = f and fl.deleted_at is null
      and case when fl.conversation_id is not null then public.can_read_conversation(fl.conversation_id)
               when fl.task_id is not null then public.can_see_task(fl.task_id)
               else public.can_see_project(fl.project_id)
          end
  );
$$;

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Sixty task changes a minute per person, one at a time.
create function public.limit_task_changes()
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform pg_advisory_xact_lock(hashtext('wasla_tasks:' || auth.uid()::text));
  if (select count(*) from task_activity
      where actor_id = auth.uid() and created_at > now() - interval '1 minute') >= 60 then
    raise exception 'too_many_requests';
  end if;
end;
$$;

-- Who a task can go to: people who see the project, and only oneself for
-- someone who doesn't lead it. Nobody given means oneself.
create function public.clean_assignees(p_project uuid, p_users uuid[])
returns uuid[]
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  people uuid[];
begin
  select coalesce(array_agg(distinct u), '{}') into people
  from unnest(p_users) u where u is not null;
  if cardinality(people) = 0 then
    people := array[auth.uid()];
  end if;
  if cardinality(people) > 20 then
    raise exception 'too_many_assignees';
  end if;
  if not public.can_manage_project(p_project) and people <> array[auth.uid()] then
    raise exception 'not_allowed';
  end if;
  if exists (select 1 from unnest(people) u where not public.user_sees_project(u, p_project)) then
    raise exception 'invalid_assignee';
  end if;
  return people;
end;
$$;

-- Reminder times: up to three, each between 5 minutes and a week ahead.
create function public.clean_offsets(p_minutes integer[])
returns integer[]
language plpgsql immutable set search_path = public, pg_temp as $$
declare
  result integer[];
begin
  if p_minutes is null then
    return '{1440,60}';
  end if;
  select coalesce(array_agg(distinct m order by m desc), '{}') into result
  from unnest(p_minutes) m where m is not null;
  if cardinality(result) > 3 or exists (select 1 from unnest(result) m where m < 5 or m > 10080) then
    raise exception 'invalid_reminder';
  end if;
  return result;
end;
$$;

-- An in-app notification about task t for each of p_users who still sees
-- the project, except whoever caused it.
create function public.notify_task(t uuid, p_users uuid[], p_kind text, p_detail text default null)
returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into notifications (user_id, workspace_id, kind, task_id, actor_id, detail)
  select distinct u, tk.workspace_id, p_kind, tk.id, auth.uid(), left(p_detail, 200)
  from tasks tk, unnest(p_users) u
  where tk.id = t and u is not null and u is distinct from auth.uid()
    and public.user_sees_project(u, tk.project_id);
$$;

-- The creator and the assignees.
create function public.task_people(t uuid)
returns uuid[]
language sql stable security definer set search_path = public, pg_temp as $$
  select array(select created_by from tasks where id = t
               union
               select user_id from task_assignees where task_id = t);
$$;

create function public.task_assignee_ids(t uuid)
returns uuid[]
language sql stable security definer set search_path = public, pg_temp as $$
  select array(select user_id from task_assignees where task_id = t);
$$;

-- Lines the automatic reminders up with the task's due time and status.
create function public.schedule_task_reminders(t uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  tk tasks%rowtype;
begin
  select * into tk from tasks where id = t;
  delete from task_reminders
  where task_id = t and kind in ('before', 'overdue') and sent_at is null;
  if tk.id is null or tk.deleted_at is not null or tk.due_at is null or tk.status = 'done' then
    return;
  end if;
  insert into task_reminders (task_id, kind, remind_at)
  select t, 'before', tk.due_at - make_interval(mins => m)
  from unnest(tk.remind_before) m
  where tk.due_at - make_interval(mins => m) > now();
  if tk.due_at > now() then
    insert into task_reminders (task_id, kind, remind_at) values (t, 'overdue', tk.due_at);
  end if;
end;
$$;

-- What the lists show for each task.
create function public.task_rows(p_ids uuid[])
returns table (
  id uuid, workspace_id uuid, workspace_name text,
  project_id uuid, project_name text, project_color text,
  title text, status public.task_status, priority public.task_priority,
  visibility public.task_visibility, due_at timestamptz,
  created_by uuid, creator_name text, assignees jsonb,
  created_at timestamptz, updated_at timestamptz, done_at timestamptz
)
language sql stable security definer set search_path = public, pg_temp as $$
  select t.id, t.workspace_id, w.name, t.project_id, p.name, p.color,
         t.title, t.status, t.priority, t.visibility, t.due_at,
         t.created_by, cp.full_name,
         coalesce((select jsonb_agg(jsonb_build_object('id', pf.id, 'name', pf.full_name)
                                    order by pf.full_name)
                   from task_assignees ta join profiles pf on pf.id = ta.user_id
                   where ta.task_id = t.id), '[]'::jsonb),
         t.created_at, t.updated_at, t.done_at
  from tasks t
  join workspaces w on w.id = t.workspace_id
  join projects p on p.id = t.project_id
  join profiles cp on cp.id = t.created_by
  where t.id = any (p_ids)
  order by t.due_at asc nulls last, t.created_at desc;
$$;

-- ---------------------------------------------------------------------------
-- Creating and changing tasks
-- ---------------------------------------------------------------------------

create function public.create_task(
  p_project        uuid,
  p_title          text,
  p_description    text                   default null,
  p_assignees      uuid[]                 default null,
  p_due_at         timestamptz            default null,
  p_priority       public.task_priority   default 'normal',
  p_visibility     public.task_visibility default 'private',
  p_remind_before  integer[]              default null,
  p_source_message uuid                   default null
) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me     uuid := auth.uid();
  pr     projects%rowtype;
  people uuid[];
  t      uuid;
begin
  select * into pr from projects where id = p_project;
  if pr.id is null or not public.can_see_project(pr.id) then
    raise exception 'not_allowed';
  end if;
  if pr.status <> 'active' then
    raise exception 'project_closed';
  end if;
  people := public.clean_assignees(pr.id, p_assignees);

  if p_source_message is not null and not exists (
       select 1 from messages m
       where m.id = p_source_message and m.workspace_id = pr.workspace_id
         and m.deleted_at is null and public.can_read_conversation(m.conversation_id)) then
    raise exception 'invalid_message';
  end if;

  perform public.limit_task_changes();

  insert into tasks (workspace_id, project_id, title, description, due_at, priority,
                     visibility, remind_before, source_message_id, created_by)
  values (pr.workspace_id, pr.id, trim(p_title), nullif(trim(p_description), ''), p_due_at,
          coalesce(p_priority, 'normal'), coalesce(p_visibility, 'private'),
          public.clean_offsets(p_remind_before), p_source_message, me)
  returning id into t;

  insert into task_assignees (task_id, user_id) select t, unnest(people);
  insert into task_activity (task_id, actor_id, kind, new_value)
  values (t, me, 'created', case when p_source_message is not null then 'message' end);

  perform public.notify_task(t, people, 'assigned');
  perform public.schedule_task_reminders(t);
  return t;
end;
$$;

-- Replaces what the task is; the app sends every field.
create function public.update_task(
  p_task          uuid,
  p_title         text,
  p_description   text,
  p_due_at        timestamptz,
  p_priority      public.task_priority,
  p_visibility    public.task_visibility,
  p_remind_before integer[]
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me uuid := auth.uid();
  tk tasks%rowtype;
begin
  select * into tk from tasks where id = p_task and deleted_at is null;
  if tk.id is null or not public.can_edit_task(tk.id) then
    raise exception 'not_allowed';
  end if;
  if not public.project_is_open(tk.project_id) then
    raise exception 'project_closed';
  end if;
  perform public.limit_task_changes();

  update tasks
  set title         = trim(p_title),
      description   = nullif(trim(p_description), ''),
      due_at        = p_due_at,
      priority      = coalesce(p_priority, tk.priority),
      visibility    = coalesce(p_visibility, tk.visibility),
      remind_before = public.clean_offsets(p_remind_before),
      updated_at    = clock_timestamp()
  where id = tk.id;

  if trim(p_title) is distinct from tk.title then
    insert into task_activity (task_id, actor_id, kind, old_value, new_value)
    values (tk.id, me, 'title', tk.title, trim(p_title));
  end if;
  if p_due_at is distinct from tk.due_at then
    insert into task_activity (task_id, actor_id, kind, old_value, new_value)
    values (tk.id, me, 'due', to_jsonb(tk.due_at) #>> '{}', to_jsonb(p_due_at) #>> '{}');
    perform public.notify_task(tk.id, public.task_assignee_ids(tk.id), 'due_changed');
  end if;
  if coalesce(p_priority, tk.priority) <> tk.priority then
    insert into task_activity (task_id, actor_id, kind, old_value, new_value)
    values (tk.id, me, 'priority', tk.priority::text, p_priority::text);
  end if;
  if coalesce(p_visibility, tk.visibility) <> tk.visibility then
    insert into task_activity (task_id, actor_id, kind, old_value, new_value)
    values (tk.id, me, 'visibility', tk.visibility::text, p_visibility::text);
  end if;

  perform public.schedule_task_reminders(tk.id);
end;
$$;

create function public.set_task_assignees(p_task uuid, p_users uuid[])
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me     uuid := auth.uid();
  tk     tasks%rowtype;
  people   uuid[];
  previous uuid[];
begin
  select * into tk from tasks where id = p_task and deleted_at is null;
  if tk.id is null or not public.can_edit_task(tk.id) then
    raise exception 'not_allowed';
  end if;
  if not public.project_is_open(tk.project_id) then
    raise exception 'project_closed';
  end if;
  people := public.clean_assignees(tk.project_id, p_users);
  previous := public.task_assignee_ids(tk.id);
  if people @> previous and previous @> people then
    return;
  end if;
  perform public.limit_task_changes();

  delete from task_assignees where task_id = tk.id and user_id <> all (people);
  insert into task_assignees (task_id, user_id)
  select tk.id, u from unnest(people) u
  on conflict do nothing;
  update tasks set updated_at = clock_timestamp() where id = tk.id;

  insert into task_activity (task_id, actor_id, kind, new_value)
  select tk.id, me, 'assignees', string_agg(p.full_name, '، ' order by p.full_name)
  from profiles p where p.id = any (people);

  perform public.notify_task(tk.id, array(select unnest(people) except select unnest(previous)),
                             'assigned');
end;
$$;

-- Assignees move a task along; the creator, a lead or an admin marks it
-- done or reopens it. Putting it on hold needs a reason.
create function public.set_task_status(
  p_task uuid, p_status public.task_status, p_reason text default null
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me        uuid := auth.uid();
  tk        tasks%rowtype;
  can_close boolean;
begin
  select * into tk from tasks where id = p_task and deleted_at is null;
  if tk.id is null or not public.is_task_party(tk.id) then
    raise exception 'not_allowed';
  end if;
  if not public.project_is_open(tk.project_id) then
    raise exception 'project_closed';
  end if;
  if p_status is null then
    raise exception 'not_allowed';
  end if;
  p_reason := nullif(trim(p_reason), '');
  if p_status = tk.status and p_reason is not distinct from tk.hold_reason then
    return;
  end if;

  can_close := tk.created_by = me or public.can_manage_project(tk.project_id);
  if (p_status = 'done' or tk.status = 'done') and not can_close then
    raise exception 'not_allowed';
  end if;
  if not (can_close or public.is_task_assignee(tk.id, me)) then
    raise exception 'not_allowed';
  end if;
  if p_status = 'on_hold' and p_reason is null then
    raise exception 'reason_required';
  end if;
  perform public.limit_task_changes();

  update tasks
  set status      = p_status,
      hold_reason = case when p_status = 'on_hold' then left(p_reason, 500) end,
      done_at     = case when p_status = 'done' then clock_timestamp() end,
      updated_at  = clock_timestamp()
  where id = tk.id;

  insert into task_activity (task_id, actor_id, kind, old_value, new_value, body)
  values (tk.id, me, 'status', tk.status::text, p_status::text,
          case when p_status = 'on_hold' then left(p_reason, 500) end);

  perform public.notify_task(tk.id, public.task_people(tk.id), 'status', p_status::text);
  perform public.schedule_task_reminders(tk.id);
end;
$$;

-- Comments are for the task's parties only.
create function public.add_task_comment(p_task uuid, p_body text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me uuid := auth.uid();
  tk tasks%rowtype;
begin
  select * into tk from tasks where id = p_task and deleted_at is null;
  if tk.id is null or not public.is_task_party(tk.id) then
    raise exception 'not_allowed';
  end if;
  if not public.project_is_open(tk.project_id) then
    raise exception 'project_closed';
  end if;
  p_body := nullif(trim(p_body), '');
  if p_body is null then
    raise exception 'empty_message';
  end if;
  perform public.limit_task_changes();

  insert into task_activity (task_id, actor_id, kind, body)
  values (tk.id, me, 'comment', p_body);
  update tasks set updated_at = clock_timestamp() where id = tk.id;
  perform public.notify_task(tk.id, public.task_people(tk.id), 'comment');
end;
$$;

-- Records an uploaded file as one of the task's attachments.
create function public.add_task_attachment(
  p_task uuid, p_path text, p_name text, p_mime text, p_size bigint
) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me uuid := auth.uid();
  tk tasks%rowtype;
  f  uuid;
begin
  select * into tk from tasks where id = p_task and deleted_at is null;
  if tk.id is null or not public.is_task_party(tk.id) then
    raise exception 'not_allowed';
  end if;
  if not public.project_is_open(tk.project_id) then
    raise exception 'project_closed';
  end if;
  perform public.limit_task_changes();

  f := public.store_file(tk.workspace_id, tk.project_id, null, p_path, p_name, p_mime, p_size);
  update files set task_id = tk.id where id = f;
  insert into task_activity (task_id, actor_id, kind, new_value, file_id)
  select tk.id, me, 'attachment', name, id from files where id = f;
  update tasks set updated_at = clock_timestamp() where id = tk.id;
  return f;
end;
$$;

-- "Remind them": an immediate reminder to the assignees, once an hour per
-- task and sender.
create function public.nudge_task(p_task uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  tk tasks%rowtype;
begin
  select * into tk from tasks where id = p_task and deleted_at is null;
  if tk.id is null or not public.can_edit_task(tk.id) then
    raise exception 'not_allowed';
  end if;
  if not public.project_is_open(tk.project_id) or tk.status = 'done' then
    raise exception 'project_closed';
  end if;
  perform pg_advisory_xact_lock(hashtext('wasla_nudge:' || tk.id::text));
  if exists (select 1 from notifications
             where task_id = tk.id and kind = 'nudge' and actor_id = auth.uid()
               and created_at > now() - interval '1 hour') then
    raise exception 'too_many_requests';
  end if;
  perform public.notify_task(tk.id, public.task_assignee_ids(tk.id), 'nudge');
end;
$$;

-- A reminder to the assignees at a time the creator picks.
create function public.add_task_reminder(p_task uuid, p_at timestamptz)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  tk tasks%rowtype;
  r  uuid;
begin
  select * into tk from tasks where id = p_task and deleted_at is null;
  if tk.id is null or not public.can_edit_task(tk.id) then
    raise exception 'not_allowed';
  end if;
  if not public.project_is_open(tk.project_id) or tk.status = 'done' then
    raise exception 'project_closed';
  end if;
  if p_at is null or p_at <= now() or p_at > now() + interval '1 year' then
    raise exception 'invalid_reminder';
  end if;
  if (select count(*) from task_reminders
      where task_id = tk.id and kind = 'custom' and sent_at is null) >= 10 then
    raise exception 'too_many_reminders';
  end if;
  insert into task_reminders (task_id, kind, remind_at, created_by)
  values (tk.id, 'custom', p_at, auth.uid())
  returning id into r;
  return r;
end;
$$;

create function public.delete_task_reminder(p_reminder uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  t uuid;
begin
  select task_id into t from task_reminders
  where id = p_reminder and kind = 'custom' and sent_at is null;
  if t is null or not public.can_edit_task(t) then
    raise exception 'not_allowed';
  end if;
  delete from task_reminders where id = p_reminder;
end;
$$;

create function public.delete_task(p_task uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  tk tasks%rowtype;
begin
  select * into tk from tasks where id = p_task and deleted_at is null;
  if tk.id is null or not public.can_edit_task(tk.id) then
    raise exception 'not_allowed';
  end if;
  if not public.project_is_open(tk.project_id) then
    raise exception 'project_closed';
  end if;
  update tasks set deleted_at = clock_timestamp(), updated_at = clock_timestamp()
  where id = tk.id;
  delete from task_reminders where task_id = tk.id and sent_at is null;
end;
$$;

-- ---------------------------------------------------------------------------
-- Reading tasks
-- ---------------------------------------------------------------------------

-- Tasks one created or is assigned, in every workspace and active project;
-- finished ones for two weeks.
create function public.my_tasks()
returns table (
  id uuid, workspace_id uuid, workspace_name text,
  project_id uuid, project_name text, project_color text,
  title text, status public.task_status, priority public.task_priority,
  visibility public.task_visibility, due_at timestamptz,
  created_by uuid, creator_name text, assignees jsonb,
  created_at timestamptz, updated_at timestamptz, done_at timestamptz
)
language sql stable security definer set search_path = public, pg_temp as $$
  select * from public.task_rows(array(
    select t.id from tasks t
    join projects p on p.id = t.project_id and p.status = 'active'
    where t.deleted_at is null
      and t.project_id in (select public.my_project_ids())
      and (t.created_by = auth.uid()
           or exists (select 1 from task_assignees ta
                      where ta.task_id = t.id and ta.user_id = auth.uid()))
      and (t.status <> 'done' or t.done_at > now() - interval '14 days')
    order by t.due_at asc nulls last
    limit 500
  ));
$$;

-- A project's tasks that one sees; finished ones for a month.
create function public.project_tasks(p_project uuid)
returns table (
  id uuid, workspace_id uuid, workspace_name text,
  project_id uuid, project_name text, project_color text,
  title text, status public.task_status, priority public.task_priority,
  visibility public.task_visibility, due_at timestamptz,
  created_by uuid, creator_name text, assignees jsonb,
  created_at timestamptz, updated_at timestamptz, done_at timestamptz
)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  manager boolean := public.can_manage_project(p_project);
begin
  if not public.can_see_project(p_project) then
    return;
  end if;
  return query
  select * from public.task_rows(array(
    select t.id from tasks t
    where t.project_id = p_project and t.deleted_at is null
      and (manager or t.visibility = 'public' or t.created_by = auth.uid()
           or exists (select 1 from task_assignees ta
                      where ta.task_id = t.id and ta.user_id = auth.uid()))
      and (t.status <> 'done' or t.done_at > now() - interval '30 days')
    order by t.due_at asc nulls last
    limit 500
  ));
end;
$$;

-- Every task in the active projects one leads in a workspace (all of them
-- for an admin), for the follow-up screen; finished ones for a month.
create function public.managed_tasks(p_workspace uuid)
returns table (
  id uuid, workspace_id uuid, workspace_name text,
  project_id uuid, project_name text, project_color text,
  title text, status public.task_status, priority public.task_priority,
  visibility public.task_visibility, due_at timestamptz,
  created_by uuid, creator_name text, assignees jsonb,
  created_at timestamptz, updated_at timestamptz, done_at timestamptz
)
language sql stable security definer set search_path = public, pg_temp as $$
  select * from public.task_rows(array(
    select t.id from tasks t
    where t.deleted_at is null
      and t.project_id in (select p.id from projects p
                           where p.workspace_id = p_workspace and p.status = 'active'
                             and public.can_manage_project(p.id))
      and (t.status <> 'done' or t.done_at > now() - interval '30 days')
    order by t.due_at asc nulls last
    limit 1000
  ));
$$;

-- One task with its attachments, its updates (comments only for its
-- parties), its custom reminders (for those who can change them) and what
-- the signed-in user may do with it.
create function public.task_detail(p_task uuid)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  me     uuid := auth.uid();
  tk     tasks%rowtype;
  party  boolean;
  editor boolean;
begin
  select * into tk from tasks where id = p_task and deleted_at is null;
  if tk.id is null or not public.can_see_task(tk.id) then
    raise exception 'not_found';
  end if;
  party  := public.is_task_party(tk.id);
  editor := public.can_edit_task(tk.id);

  return jsonb_build_object(
    'task',          (select to_jsonb(r) from public.task_rows(array[tk.id]) r),
    'description',   tk.description,
    'hold_reason',   tk.hold_reason,
    'remind_before', to_jsonb(tk.remind_before),
    'project_open',  public.project_is_open(tk.project_id),
    'is_party',      party,
    'can_edit',      editor,
    'can_close',     tk.created_by = me or public.can_manage_project(tk.project_id),
    'is_assignee',   public.is_task_assignee(tk.id, me),
    'source_conversation_id',
      (select m.conversation_id from messages m
       where m.id = tk.source_message_id and m.deleted_at is null
         and public.can_read_conversation(m.conversation_id)),
    'files', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', f.id, 'name', f.name, 'mime', f.mime, 'size_bytes', f.size_bytes,
               'storage_path', f.storage_path, 'pinned', f.pinned,
               'uploaded_by', f.uploaded_by, 'uploader_name', p.full_name,
               'created_at', f.created_at) order by f.created_at)
      from files f join profiles p on p.id = f.uploaded_by
      where f.task_id = tk.id and f.deleted_at is null), '[]'::jsonb),
    'activity', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', a.id, 'kind', a.kind, 'actor_id', a.actor_id, 'actor_name', p.full_name,
               'old_value', a.old_value, 'new_value', a.new_value, 'body', a.body,
               'created_at', a.created_at) order by a.created_at)
      from task_activity a join profiles p on p.id = a.actor_id
      where a.task_id = tk.id and (party or a.kind <> 'comment')), '[]'::jsonb),
    'reminders', case when editor then coalesce((
      select jsonb_agg(jsonb_build_object('id', r.id, 'remind_at', r.remind_at)
                       order by r.remind_at)
      from task_reminders r
      where r.task_id = tk.id and r.kind = 'custom' and r.sent_at is null), '[]'::jsonb)
      else '[]'::jsonb end
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Notifications
-- ---------------------------------------------------------------------------

create function public.my_notifications(p_limit integer default 50)
returns table (
  id uuid, kind text, task_id uuid, task_title text,
  project_name text, project_color text, workspace_id uuid, workspace_name text,
  actor_name text, detail text, created_at timestamptz, read_at timestamptz
)
language sql stable security definer set search_path = public, pg_temp as $$
  select n.id, n.kind, n.task_id, t.title, p.name, p.color, n.workspace_id, w.name,
         a.full_name, n.detail, n.created_at, n.read_at
  from notifications n
  join workspaces w on w.id = n.workspace_id
  left join tasks t on t.id = n.task_id
  left join projects p on p.id = t.project_id
  left join profiles a on a.id = n.actor_id
  where n.user_id = auth.uid()
    and (n.task_id is null or public.can_see_task(n.task_id))
  order by n.created_at desc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
$$;

-- Marks the given notifications read, or all of them.
create function public.mark_notifications_read(p_ids uuid[] default null)
returns void
language sql security definer set search_path = public, pg_temp as $$
  update notifications set read_at = clock_timestamp()
  where user_id = auth.uid() and read_at is null
    and (p_ids is null or id = any (p_ids));
$$;

-- Run every minute: turns reminders that are due into notifications.
-- Returns how many reminders went out.
create function public.process_task_reminders()
returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r    record;
  sent integer := 0;
begin
  for r in
    select tr.id, tr.kind, t.id as task_id, t.status, t.due_at, t.deleted_at, t.created_by,
           p.status as project_status
    from task_reminders tr
    join tasks t on t.id = tr.task_id
    join projects p on p.id = t.project_id
    where tr.sent_at is null and tr.remind_at <= now()
    order by tr.remind_at
    limit 1000
    for update of tr skip locked
  loop
    update task_reminders set sent_at = now() where id = r.id;
    continue when r.deleted_at is not null or r.status = 'done' or r.project_status <> 'active';

    if r.kind = 'before' then
      -- Nothing to warn about once it is in review or already late.
      continue when r.status = 'review' or r.due_at is null or r.due_at <= now();
      perform public.notify_task(r.task_id, public.task_assignee_ids(r.task_id), 'due_soon');
    elsif r.kind = 'overdue' then
      perform public.notify_task(
        r.task_id,
        case when r.status = 'review' then array[r.created_by]
             else public.task_people(r.task_id) end,
        'overdue');
    else
      perform public.notify_task(r.task_id, public.task_assignee_ids(r.task_id), 'reminder');
    end if;
    sent := sent + 1;
  end loop;
  return sent;
end;
$$;

-- ---------------------------------------------------------------------------
-- Row Level Security. Tasks and one's own notifications are readable
-- directly so the app can follow them live; the rest goes through the
-- functions above.
-- ---------------------------------------------------------------------------

alter table public.tasks          enable row level security;
alter table public.task_assignees enable row level security;
alter table public.task_activity  enable row level security;
alter table public.task_reminders enable row level security;
alter table public.notifications  enable row level security;

revoke all on public.tasks, public.task_assignees, public.task_activity,
              public.task_reminders, public.notifications
from anon, authenticated;

grant select on public.tasks to authenticated;
create policy tasks_read on public.tasks for select to authenticated
  using (public.can_see_task(id));

grant select on public.notifications to authenticated;
create policy notifications_read on public.notifications for select to authenticated
  using (user_id = auth.uid());

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.tasks, public.notifications;
  end if;
end $$;

-- Every minute, where pg_cron is available (it is on Supabase; the local
-- test server has none, and its tests call process_task_reminders directly).
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron with schema pg_catalog;
    grant usage on schema cron to postgres;
    grant all privileges on all tables in schema cron to postgres;
    perform cron.schedule('wasla-task-reminders', '* * * * *',
                          'select public.process_task_reminders()');
  else
    raise notice 'pg_cron is not available here; task reminders are not scheduled';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Function privileges
-- ---------------------------------------------------------------------------

revoke execute on function
  public.my_project_ids(),
  public.is_task_assignee(uuid, uuid),
  public.is_task_party(uuid),
  public.can_see_task(uuid),
  public.can_edit_task(uuid),
  public.can_see_file(uuid),
  public.limit_task_changes(),
  public.clean_assignees(uuid, uuid[]),
  public.clean_offsets(integer[]),
  public.notify_task(uuid, uuid[], text, text),
  public.task_people(uuid),
  public.task_assignee_ids(uuid),
  public.schedule_task_reminders(uuid),
  public.task_rows(uuid[]),
  public.create_task(uuid, text, text, uuid[], timestamptz, public.task_priority,
                     public.task_visibility, integer[], uuid),
  public.update_task(uuid, text, text, timestamptz, public.task_priority,
                     public.task_visibility, integer[]),
  public.set_task_assignees(uuid, uuid[]),
  public.set_task_status(uuid, public.task_status, text),
  public.add_task_comment(uuid, text),
  public.add_task_attachment(uuid, text, text, text, bigint),
  public.nudge_task(uuid),
  public.add_task_reminder(uuid, timestamptz),
  public.delete_task_reminder(uuid),
  public.delete_task(uuid),
  public.my_tasks(),
  public.project_tasks(uuid),
  public.managed_tasks(uuid),
  public.task_detail(uuid),
  public.my_notifications(integer),
  public.mark_notifications_read(uuid[]),
  public.process_task_reminders()
from public, anon, authenticated;

-- The read policy's helper and the actions the app calls.
grant execute on function
  public.can_see_task(uuid),
  public.create_task(uuid, text, text, uuid[], timestamptz, public.task_priority,
                     public.task_visibility, integer[], uuid),
  public.update_task(uuid, text, text, timestamptz, public.task_priority,
                     public.task_visibility, integer[]),
  public.set_task_assignees(uuid, uuid[]),
  public.set_task_status(uuid, public.task_status, text),
  public.add_task_comment(uuid, text),
  public.add_task_attachment(uuid, text, text, text, bigint),
  public.nudge_task(uuid),
  public.add_task_reminder(uuid, timestamptz),
  public.delete_task_reminder(uuid),
  public.delete_task(uuid),
  public.my_tasks(),
  public.project_tasks(uuid),
  public.managed_tasks(uuid),
  public.task_detail(uuid),
  public.my_notifications(integer),
  public.mark_notifications_read(uuid[])
to authenticated;
