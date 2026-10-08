-- Phase 3 review: fixes to tasks, reminders and notifications.
--
-- * Task changes lock the task row, so two people acting at once can't slip
--   past each other's checks (an assignee reopening a task the creator just
--   closed).
-- * Someone who doesn't lead a project can't strip a task's other assignees
--   when they edit it; they only add or remove themselves.
-- * Every task write counts toward the per-person rate limit, and edits
--   that change nothing do nothing.
-- * The tasks read policy runs its permission checks once per query, not
--   once per row of every tenant.
-- * Deleting a task removes its attachments too (freeing the plan's
--   storage) and tells the people on it; people taken off a task are told
--   as well, which also refreshes their lists.
-- * Reopening an archived or closed project schedules its tasks' reminders
--   again.
-- * Lists keep open tasks ahead of finished ones when they hit their limit.

-- ---------------------------------------------------------------------------
-- Rate limit: sixty task writes a minute per person, counted on every write
-- ---------------------------------------------------------------------------

create table public.task_writes (
  user_id uuid not null references public.profiles (id) on delete cascade,
  at      timestamptz not null default clock_timestamp()
);

create index task_writes_user_idx on public.task_writes (user_id, at);

alter table public.task_writes enable row level security;
revoke all on public.task_writes from anon, authenticated;

create or replace function public.limit_task_changes()
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform pg_advisory_xact_lock(hashtext('wasla_tasks:' || auth.uid()::text));
  delete from task_writes where user_id = auth.uid() and at < now() - interval '1 minute';
  if (select count(*) from task_writes where user_id = auth.uid()) >= 60 then
    raise exception 'too_many_requests';
  end if;
  insert into task_writes (user_id) values (auth.uid());
end;
$$;

-- ---------------------------------------------------------------------------
-- Notifications for people taken off a task, and for a deleted task
-- ---------------------------------------------------------------------------

alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('assigned', 'status', 'comment', 'due_changed', 'nudge',
                  'due_soon', 'overdue', 'reminder', 'unassigned', 'deleted'));

-- They stay in the list after the task is gone from the reader's view, under
-- the title it had when they were sent (kept in detail), not a later one.
create or replace function public.my_notifications(p_limit integer default 50)
returns table (
  id uuid, kind text, task_id uuid, task_title text,
  project_name text, project_color text, workspace_id uuid, workspace_name text,
  actor_name text, detail text, created_at timestamptz, read_at timestamptz
)
language sql stable security definer set search_path = public, pg_temp as $$
  select n.id, n.kind, n.task_id,
         case when n.kind in ('unassigned', 'deleted') then coalesce(n.detail, t.title)
              else t.title end,
         p.name, p.color, n.workspace_id, w.name,
         a.full_name, n.detail, n.created_at, n.read_at
  from notifications n
  join workspaces w on w.id = n.workspace_id
  left join tasks t on t.id = n.task_id
  left join projects p on p.id = t.project_id
  left join profiles a on a.id = n.actor_id
  where n.user_id = auth.uid()
    and (n.task_id is null or n.kind in ('unassigned', 'deleted')
         or public.can_see_task(n.task_id))
  order by n.created_at desc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
$$;

-- ---------------------------------------------------------------------------
-- Assignees
-- ---------------------------------------------------------------------------

-- Who a task can go to when its assignees change from p_previous: anyone
-- who sees the project for a lead or admin; otherwise the same people, with
-- or without oneself.
create function public.clean_assignees(p_project uuid, p_users uuid[], p_previous uuid[])
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
  if not public.can_manage_project(p_project) and exists (
       select 1 from ((select unnest(people) except select unnest(p_previous))
                      union all
                      (select unnest(p_previous) except select unnest(people))) d(u)
       where u is distinct from auth.uid()) then
    raise exception 'not_allowed';
  end if;
  if exists (select 1 from unnest(people) u
             where u <> all (p_previous) and not public.user_sees_project(u, p_project)) then
    raise exception 'invalid_assignee';
  end if;
  return people;
end;
$$;

create or replace function public.set_task_assignees(p_task uuid, p_users uuid[])
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me       uuid := auth.uid();
  tk       tasks%rowtype;
  people   uuid[];
  previous uuid[];
begin
  select * into tk from tasks where id = p_task and deleted_at is null for update;
  if tk.id is null then
    raise exception 'not_found';
  end if;
  if not public.can_edit_task(tk.id) then
    raise exception 'not_allowed';
  end if;
  if not public.project_is_open(tk.project_id) then
    raise exception 'project_closed';
  end if;
  previous := public.task_assignee_ids(tk.id);
  people := public.clean_assignees(tk.project_id, p_users, previous);
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
  perform public.notify_task(tk.id, array(select unnest(previous) except select unnest(people)),
                             'unassigned', tk.title);
end;
$$;

-- ---------------------------------------------------------------------------
-- Changing a task: lock it first, and do nothing when nothing changes
-- ---------------------------------------------------------------------------

create or replace function public.update_task(
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
  me          uuid := auth.uid();
  tk          tasks%rowtype;
  v_title       text := trim(p_title);
  v_description text := nullif(trim(p_description), '');
  v_priority    public.task_priority;
  v_visibility  public.task_visibility;
  v_offsets     integer[] := public.clean_offsets(p_remind_before);
begin
  select * into tk from tasks where id = p_task and deleted_at is null for update;
  if tk.id is null then
    raise exception 'not_found';
  end if;
  if not public.can_edit_task(tk.id) then
    raise exception 'not_allowed';
  end if;
  if not public.project_is_open(tk.project_id) then
    raise exception 'project_closed';
  end if;
  v_priority   := coalesce(p_priority, tk.priority);
  v_visibility := coalesce(p_visibility, tk.visibility);
  if v_title is not distinct from tk.title
     and v_description is not distinct from tk.description
     and p_due_at is not distinct from tk.due_at
     and v_priority = tk.priority and v_visibility = tk.visibility
     and v_offsets = tk.remind_before then
    return;
  end if;
  perform public.limit_task_changes();

  update tasks
  set title         = v_title,
      description   = v_description,
      due_at        = p_due_at,
      priority      = v_priority,
      visibility    = v_visibility,
      remind_before = v_offsets,
      updated_at    = clock_timestamp()
  where id = tk.id;

  if v_title is distinct from tk.title then
    insert into task_activity (task_id, actor_id, kind, old_value, new_value)
    values (tk.id, me, 'title', tk.title, v_title);
  end if;
  if p_due_at is distinct from tk.due_at then
    insert into task_activity (task_id, actor_id, kind, old_value, new_value)
    values (tk.id, me, 'due', to_jsonb(tk.due_at) #>> '{}', to_jsonb(p_due_at) #>> '{}');
    perform public.notify_task(tk.id, public.task_assignee_ids(tk.id), 'due_changed');
  end if;
  if v_priority <> tk.priority then
    insert into task_activity (task_id, actor_id, kind, old_value, new_value)
    values (tk.id, me, 'priority', tk.priority::text, v_priority::text);
  end if;
  if v_visibility <> tk.visibility then
    insert into task_activity (task_id, actor_id, kind, old_value, new_value)
    values (tk.id, me, 'visibility', tk.visibility::text, v_visibility::text);
  end if;

  perform public.schedule_task_reminders(tk.id);
end;
$$;

-- Assignees move a task along; the creator, a lead or an admin marks it
-- done or reopens it. Putting it on hold needs a reason, and a new reason
-- for a task already on hold is a change too.
create or replace function public.set_task_status(
  p_task uuid, p_status public.task_status, p_reason text default null
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me        uuid := auth.uid();
  tk        tasks%rowtype;
  can_close boolean;
begin
  select * into tk from tasks where id = p_task and deleted_at is null for update;
  if tk.id is null then
    raise exception 'not_found';
  end if;
  if not public.is_task_party(tk.id) then
    raise exception 'not_allowed';
  end if;
  if not public.project_is_open(tk.project_id) then
    raise exception 'project_closed';
  end if;
  if p_status is null then
    raise exception 'not_allowed';
  end if;
  p_reason := nullif(trim(p_reason), '');
  if p_status = tk.status
     and (p_status <> 'on_hold' or p_reason is null
          or left(p_reason, 500) is not distinct from tk.hold_reason) then
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

create or replace function public.add_task_comment(p_task uuid, p_body text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me uuid := auth.uid();
  tk tasks%rowtype;
begin
  select * into tk from tasks where id = p_task and deleted_at is null;
  if tk.id is null then
    raise exception 'not_found';
  end if;
  if not public.is_task_party(tk.id) then
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

create or replace function public.add_task_attachment(
  p_task uuid, p_path text, p_name text, p_mime text, p_size bigint
) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me uuid := auth.uid();
  tk tasks%rowtype;
  f  uuid;
begin
  select * into tk from tasks where id = p_task and deleted_at is null for update;
  if tk.id is null then
    raise exception 'not_found';
  end if;
  if not public.is_task_party(tk.id) then
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

create or replace function public.nudge_task(p_task uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  tk tasks%rowtype;
begin
  select * into tk from tasks where id = p_task and deleted_at is null;
  if tk.id is null then
    raise exception 'not_found';
  end if;
  if not public.can_edit_task(tk.id) or tk.status = 'done' then
    raise exception 'not_allowed';
  end if;
  if not public.project_is_open(tk.project_id) then
    raise exception 'project_closed';
  end if;
  perform public.limit_task_changes();
  if exists (select 1 from notifications
             where task_id = tk.id and kind = 'nudge' and actor_id = auth.uid()
               and created_at > now() - interval '1 hour') then
    raise exception 'too_many_requests';
  end if;
  perform public.notify_task(tk.id, public.task_assignee_ids(tk.id), 'nudge');
end;
$$;

-- A reminder to the assignees at a time the creator picks, up to two years
-- ahead (as far as a due date can be).
create or replace function public.add_task_reminder(p_task uuid, p_at timestamptz)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  tk tasks%rowtype;
  r  uuid;
begin
  select * into tk from tasks where id = p_task and deleted_at is null for update;
  if tk.id is null then
    raise exception 'not_found';
  end if;
  if not public.can_edit_task(tk.id) or tk.status = 'done' then
    raise exception 'not_allowed';
  end if;
  if not public.project_is_open(tk.project_id) then
    raise exception 'project_closed';
  end if;
  if p_at is null or p_at <= now() or p_at > now() + interval '2 years' then
    raise exception 'invalid_reminder';
  end if;
  if (select count(*) from task_reminders
      where task_id = tk.id and kind = 'custom' and sent_at is null) >= 10 then
    raise exception 'too_many_reminders';
  end if;
  perform public.limit_task_changes();
  insert into task_reminders (task_id, kind, remind_at, created_by)
  values (tk.id, 'custom', p_at, auth.uid())
  returning id into r;
  return r;
end;
$$;

create or replace function public.delete_task_reminder(p_reminder uuid)
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
  perform public.limit_task_changes();
  delete from task_reminders where id = p_reminder;
end;
$$;

-- Deleting a task takes its attachments with it and tells its people.
create or replace function public.delete_task(p_task uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  tk tasks%rowtype;
begin
  select * into tk from tasks where id = p_task and deleted_at is null for update;
  if tk.id is null then
    raise exception 'not_found';
  end if;
  if not public.can_edit_task(tk.id) then
    raise exception 'not_allowed';
  end if;
  if not public.project_is_open(tk.project_id) then
    raise exception 'project_closed';
  end if;
  perform public.limit_task_changes();
  perform public.notify_task(tk.id, public.task_people(tk.id), 'deleted', tk.title);
  update tasks set deleted_at = clock_timestamp(), updated_at = clock_timestamp()
  where id = tk.id;
  update files set deleted_at = clock_timestamp()
  where task_id = tk.id and deleted_at is null;
  delete from task_reminders where task_id = tk.id and sent_at is null;
end;
$$;

-- A task attachment removed from the project's files: open task screens
-- follow the task's changes, so the task changes too.
create function public.touch_task_on_file()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update tasks set updated_at = clock_timestamp()
  where id = new.task_id and deleted_at is null;
  return null;
end;
$$;

create trigger files_touch_task
  after update of deleted_at on public.files
  for each row
  when (new.task_id is not null and old.deleted_at is null and new.deleted_at is not null)
  execute function public.touch_task_on_file();

-- ---------------------------------------------------------------------------
-- Reopened projects get their reminders back
-- ---------------------------------------------------------------------------

create function public.reschedule_project_reminders()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.schedule_task_reminders(t.id)
  from tasks t
  where t.project_id = new.id and t.deleted_at is null and t.status <> 'done';
  return null;
end;
$$;

create trigger projects_reopen_reminders
  after update of status on public.projects
  for each row
  when (old.status <> 'active' and new.status = 'active')
  execute function public.reschedule_project_reminders();

-- ---------------------------------------------------------------------------
-- Reading tasks
-- ---------------------------------------------------------------------------

-- The tasks one is assigned, and the projects one leads or administers:
-- sets the read policy checks once per query.
create function public.my_task_ids()
returns setof uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select task_id from task_assignees where user_id = auth.uid();
$$;

create function public.my_managed_project_ids()
returns setof uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select pr.id
  from projects pr
  join workspace_members wm
    on wm.workspace_id = pr.workspace_id and wm.user_id = auth.uid() and wm.status = 'active'
  where wm.role in ('owner', 'admin')
     or exists (select 1 from project_members pm
                where pm.project_id = pr.id and pm.user_id = auth.uid() and pm.role = 'lead');
$$;

drop policy tasks_read on public.tasks;
create policy tasks_read on public.tasks for select to authenticated
  using (deleted_at is null
         and project_id in (select public.my_project_ids())
         and (visibility = 'public'
              or created_by = (select auth.uid())
              or id in (select public.my_task_ids())
              or project_id in (select public.my_managed_project_ids())));

-- Open tasks come first, so a long list drops old finished ones, not work.
create or replace function public.my_tasks()
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
    order by t.status = 'done', t.due_at asc nulls last
    limit 500
  ));
$$;

create or replace function public.project_tasks(p_project uuid)
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
    order by t.status = 'done', t.due_at asc nulls last
    limit 500
  ));
end;
$$;

create or replace function public.managed_tasks(p_workspace uuid)
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
    order by t.status = 'done', t.due_at asc nulls last
    limit 1000
  ));
$$;

-- Adds whether the reader can change who the task is for.
create or replace function public.task_detail(p_task uuid)
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
    'can_assign',    public.can_manage_project(tk.project_id),
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
-- Function privileges
-- ---------------------------------------------------------------------------

revoke execute on function
  public.clean_assignees(uuid, uuid[], uuid[]),
  public.touch_task_on_file(),
  public.reschedule_project_reminders(),
  public.my_task_ids(),
  public.my_managed_project_ids()
from public, anon, authenticated;

-- The read policy's helpers: each returns only the reader's own ids.
grant execute on function
  public.my_project_ids(),
  public.my_task_ids(),
  public.my_managed_project_ids()
to authenticated;
