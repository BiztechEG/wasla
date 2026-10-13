-- Recurring tasks and task templates.
--
-- A task can repeat daily, weekly or monthly from its due time. Its next
-- occurrence is made once it is done or once its due time passes, whichever
-- comes first, so a weekly task appears every week by itself. Each
-- occurrence makes the next one only once.
--
-- A template is a named list of tasks, kept per workspace, that can be
-- added to any project in one go (for projects that repeat).

alter type public.task_event add value if not exists 'repeat';

alter table public.tasks
  add column repeat text check (repeat in ('daily', 'weekly', 'monthly')),
  add column repeat_next uuid references public.tasks (id) on delete set null;

create index tasks_repeat_due_idx on public.tasks (due_at)
  where repeat is not null and repeat_next is null and deleted_at is null;

-- The due time after [due] for [repeat], past now.
create function public.next_due(p_due timestamptz, p_repeat text)
returns timestamptz
language plpgsql stable set search_path = public, pg_temp as $$
declare
  step interval := case p_repeat when 'daily' then interval '1 day'
                                 when 'weekly' then interval '7 days'
                                 else interval '1 month' end;
  n    integer := 1;
  d    timestamptz;
begin
  loop
    -- Months are counted from the first due time, so the 31st stays the
    -- last day of short months instead of drifting.
    d := p_due + step * n;
    exit when d > now() or n > 4000;
    n := n + 1;
  end loop;
  return d;
end;
$$;

-- Makes the next occurrence of task t, once.
create function public.spawn_next_task(t uuid)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  tk   tasks%rowtype;
  nxt  uuid;
  due  timestamptz;
  people uuid[];
begin
  select * into tk from tasks where id = t for update;
  if tk.id is null or tk.repeat is null or tk.repeat_next is not null
     or tk.deleted_at is not null or tk.due_at is null
     or not public.project_is_open(tk.project_id) then
    return null;
  end if;
  due := public.next_due(tk.due_at, tk.repeat);

  insert into tasks (workspace_id, project_id, title, description, due_at, priority,
                     visibility, remind_before, created_by, repeat)
  values (tk.workspace_id, tk.project_id, tk.title, tk.description, due, tk.priority,
          tk.visibility, tk.remind_before, tk.created_by, tk.repeat)
  returning id into nxt;

  -- The same people, as long as they are still in the project.
  people := array(select ta.user_id from task_assignees ta
                  where ta.task_id = tk.id and public.user_sees_project(ta.user_id, tk.project_id));
  if cardinality(people) = 0 then
    people := array[tk.created_by];
  end if;
  insert into task_assignees (task_id, user_id) select nxt, unnest(people);
  insert into task_activity (task_id, actor_id, kind, new_value)
  values (nxt, tk.created_by, 'created', 'repeat');

  update tasks set repeat_next = nxt where id = tk.id;
  perform public.notify_task(nxt, people, 'assigned');
  perform public.schedule_task_reminders(nxt);
  return nxt;
end;
$$;

create function public.spawn_on_done()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.spawn_next_task(new.id);
  return null;
end;
$$;

create trigger tasks_repeat_on_done
  after update of status on public.tasks
  for each row when (new.status = 'done' and old.status <> 'done' and new.repeat is not null)
  execute function public.spawn_on_done();

-- Occurrences whose due time has passed; run by pg_cron.
create function public.process_recurring_tasks()
returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r    record;
  made integer := 0;
begin
  for r in
    select id from tasks
    where repeat is not null and repeat_next is null and deleted_at is null
      and due_at <= now()
    order by due_at
    limit 500
  loop
    if public.spawn_next_task(r.id) is not null then
      made := made + 1;
    end if;
  end loop;
  return made;
end;
$$;

-- Sets or stops a task's repeating. It needs a due time to repeat from.
create function public.set_task_repeat(p_task uuid, p_repeat text)
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
  p_repeat := nullif(p_repeat, '');
  if p_repeat is not null and p_repeat not in ('daily', 'weekly', 'monthly') then
    raise exception 'invalid_repeat';
  end if;
  if p_repeat is not null and tk.due_at is null then
    raise exception 'due_required';
  end if;
  if p_repeat is not distinct from tk.repeat then
    return;
  end if;
  perform public.limit_task_changes();
  update tasks set repeat = p_repeat, updated_at = clock_timestamp() where id = tk.id;
  insert into task_activity (task_id, actor_id, kind, old_value, new_value)
  values (tk.id, auth.uid(), 'repeat', tk.repeat, p_repeat);
  -- Already done: the next one is due now.
  if p_repeat is not null and tk.status = 'done' then
    perform public.spawn_next_task(tk.id);
  end if;
end;
$$;


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
    'repeat',        tk.repeat,
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
-- Templates
-- ---------------------------------------------------------------------------

create table public.task_templates (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  name         text not null check (length(trim(name)) > 0 and length(name) <= 100),
  -- [{title, description, priority, due_in_days}], at most 50.
  items        jsonb not null check (jsonb_typeof(items) = 'array'
                                     and jsonb_array_length(items) between 1 and 50),
  created_by   uuid not null references public.profiles (id),
  created_at   timestamptz not null default clock_timestamp()
);

create index task_templates_workspace_idx on public.task_templates (workspace_id, name);

alter table public.task_templates enable row level security;
revoke all on public.task_templates from anon, authenticated;

-- Whoever leads a project or administers the workspace keeps templates.
create function public.can_keep_templates(p_workspace uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select public.is_workspace_admin(p_workspace)
      or exists (select 1 from project_members pm
                 join projects pr on pr.id = pm.project_id
                 where pr.workspace_id = p_workspace and pm.user_id = auth.uid()
                   and pm.role = 'lead');
$$;

create function public.task_templates(p_workspace uuid)
returns table (id uuid, name text, items jsonb, created_by uuid, creator_name text,
               created_at timestamptz, can_delete boolean)
language sql stable security definer set search_path = public, pg_temp as $$
  select t.id, t.name, t.items, t.created_by, p.full_name, t.created_at,
         t.created_by = auth.uid() or public.is_workspace_admin(p_workspace)
  from task_templates t
  join profiles p on p.id = t.created_by
  where t.workspace_id = p_workspace and public.is_workspace_member(p_workspace)
  order by t.name;
$$;

create function public.save_task_template(p_workspace uuid, p_name text, p_items jsonb)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  items jsonb;
  t     uuid;
begin
  if not public.can_keep_templates(p_workspace) then
    raise exception 'not_allowed';
  end if;
  if jsonb_typeof(p_items) <> 'array' then
    raise exception 'invalid_template';
  end if;
  -- Only what a task needs, trimmed to the task's own limits.
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'title', left(trim(i ->> 'title'), 200),
           'description', nullif(left(trim(i ->> 'description'), 4000), ''),
           'priority', case when i ->> 'priority' in ('normal', 'high', 'urgent')
                            then i ->> 'priority' else 'normal' end,
           'due_in_days', case when (i ->> 'due_in_days') ~ '^[0-9]{1,3}$'
                               then (i ->> 'due_in_days')::int end))
           order by o), '[]'::jsonb)
  into items
  from jsonb_array_elements(p_items) with ordinality as e(i, o)
  where jsonb_typeof(i) = 'object' and length(trim(coalesce(i ->> 'title', ''))) > 0;
  if jsonb_array_length(items) not between 1 and 50 then
    raise exception 'invalid_template';
  end if;
  if (select count(*) from task_templates where workspace_id = p_workspace) >= 100 then
    raise exception 'too_many_requests';
  end if;
  insert into task_templates (workspace_id, name, items, created_by)
  values (p_workspace, left(trim(p_name), 100), items, auth.uid())
  returning id into t;
  return t;
end;
$$;

create function public.delete_task_template(p_template uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  tp task_templates%rowtype;
begin
  select * into tp from task_templates where id = p_template;
  if tp.id is null
     or not (tp.created_by = auth.uid() or public.is_workspace_admin(tp.workspace_id)) then
    raise exception 'not_allowed';
  end if;
  delete from task_templates where id = tp.id;
end;
$$;

-- Adds a template's tasks to a project, for [p_assignees] (oneself when
-- none; others only by someone who leads it, as with any task), due the given
-- number of days after [p_start] (the app sends today at 5 pm, local time).
-- Returns how many.
create function public.apply_task_template(p_template uuid, p_project uuid,
                                           p_assignees uuid[] default null,
                                           p_start timestamptz default null)
returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  tp    task_templates%rowtype;
  pr    projects%rowtype;
  i     jsonb;
  made  integer := 0;
begin
  select * into tp from task_templates where id = p_template;
  select * into pr from projects where id = p_project;
  if tp.id is null or pr.id is null or tp.workspace_id <> pr.workspace_id
     or not public.can_see_project(pr.id) then
    raise exception 'not_allowed';
  end if;
  for i in select value from jsonb_array_elements(tp.items) loop
    perform public.create_task(
      pr.id, i ->> 'title', i ->> 'description', p_assignees,
      case when i ? 'due_in_days'
           then coalesce(p_start, date_trunc('day', now()) + interval '17 hours')
                + make_interval(days => (i ->> 'due_in_days')::int) end,
      coalesce(i ->> 'priority', 'normal')::public.task_priority);
    made := made + 1;
  end loop;
  return made;
end;
$$;

-- Every five minutes, where pg_cron is available (tests call
-- process_recurring_tasks directly).
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron with schema pg_catalog;
    perform cron.schedule('wasla-recurring-tasks', '*/5 * * * *',
                          'select public.process_recurring_tasks()');
  else
    raise notice 'pg_cron is not available here; recurring tasks are not scheduled';
  end if;
end $$;

revoke execute on function
  public.next_due(timestamptz, text),
  public.spawn_next_task(uuid),
  public.spawn_on_done(),
  public.process_recurring_tasks(),
  public.set_task_repeat(uuid, text),
  public.can_keep_templates(uuid),
  public.task_templates(uuid),
  public.save_task_template(uuid, text, jsonb),
  public.delete_task_template(uuid),
  public.apply_task_template(uuid, uuid, uuid[], timestamptz)
from public, anon, authenticated;

grant execute on function
  public.set_task_repeat(uuid, text),
  public.can_keep_templates(uuid),
  public.task_templates(uuid),
  public.save_task_template(uuid, text, jsonb),
  public.delete_task_template(uuid),
  public.apply_task_template(uuid, uuid, uuid[], timestamptz)
to authenticated;
