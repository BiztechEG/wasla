-- Wasla: managing workspaces.
-- * Owners and admins rename a workspace (already allowed on workspaces.name).
-- * Anyone leaves a workspace; the last owner cannot.
-- * A workspace owner or the company owner deletes a workspace by typing its
--   name. It is hidden and locked at once, can be restored for 30 days, and
--   is then removed for good with its chats, tasks and files (the nightly
--   file cleanup removes stored files nobody uses any more). Invoices keep
--   their lines.

alter table public.workspaces
  add column deleted_at timestamptz,
  add column deleted_by uuid references public.profiles (id);

create index workspaces_deleted_idx on public.workspaces (deleted_at)
  where deleted_at is not null;

-- ---------------------------------------------------------------------------
-- A deleted workspace has no members as far as permissions go.
-- ---------------------------------------------------------------------------

create or replace function public.workspace_role_of(ws uuid)
returns public.workspace_role
language sql stable security definer set search_path = public, pg_temp as $$
  select wm.role from workspace_members wm
  join workspaces w on w.id = wm.workspace_id and w.deleted_at is null
  where wm.workspace_id = ws and wm.user_id = auth.uid() and wm.status = 'active';
$$;

create or replace function public.shares_workspace(other uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1
    from workspace_members a
    join workspace_members b on b.workspace_id = a.workspace_id
    join workspaces w on w.id = a.workspace_id and w.deleted_at is null
    where a.user_id = auth.uid() and a.status = 'active'
      and b.user_id = other and b.status = 'active'
  );
$$;

create or replace function public.user_sees_project(u uuid, p uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from projects pr
    join workspaces w on w.id = pr.workspace_id and w.deleted_at is null
    join workspace_members wm
      on wm.workspace_id = pr.workspace_id and wm.user_id = u and wm.status = 'active'
    where pr.id = p
      and (wm.role in ('owner', 'admin')
           or exists (select 1 from project_members pm
                      where pm.project_id = p and pm.user_id = u))
  );
$$;

create or replace function public.my_conversation_ids()
returns setof uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select cv.id from conversations cv
  join workspaces w on w.id = cv.workspace_id and w.deleted_at is null
  join workspace_members wm
    on wm.workspace_id = cv.workspace_id and wm.user_id = auth.uid() and wm.status = 'active'
  where (cv.kind = 'direct' and auth.uid() in (cv.user_a, cv.user_b))
     or (cv.kind = 'project' and public.can_see_project(cv.project_id));
$$;

create or replace function public.my_project_ids()
returns setof uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select pr.id
  from projects pr
  join workspaces w on w.id = pr.workspace_id and w.deleted_at is null
  join workspace_members wm
    on wm.workspace_id = pr.workspace_id and wm.user_id = auth.uid() and wm.status = 'active'
  where wm.role in ('owner', 'admin')
     or exists (select 1 from project_members pm
                where pm.project_id = pr.id and pm.user_id = auth.uid());
$$;

create or replace function public.my_managed_project_ids()
returns setof uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select pr.id
  from projects pr
  join workspaces w on w.id = pr.workspace_id and w.deleted_at is null
  join workspace_members wm
    on wm.workspace_id = pr.workspace_id and wm.user_id = auth.uid() and wm.status = 'active'
  where wm.role in ('owner', 'admin')
     or exists (select 1 from project_members pm
                where pm.project_id = pr.id and pm.user_id = auth.uid() and pm.role = 'lead');
$$;

create or replace function public.search_workspaces(p_query text)
returns table (id uuid, name text)
language sql stable security definer set search_path = public, pg_temp as $$
  select w.id, w.name
  from workspaces w
  where w.discoverable and w.deleted_at is null
    and length(trim(p_query)) >= 2
    and w.name ilike '%' || replace(replace(replace(trim(p_query),
          '\', '\\'), '%', '\%'), '_', '\_') || '%' escape '\'
  order by w.name
  limit 20;
$$;

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
  join workspaces w on w.id = n.workspace_id and w.deleted_at is null
  left join tasks t on t.id = n.task_id
  left join projects p on p.id = t.project_id
  left join profiles a on a.id = n.actor_id
  where n.user_id = auth.uid()
    and (n.task_id is null or n.kind in ('unassigned', 'deleted')
         or public.can_see_task(n.task_id))
  order by n.created_at desc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
$$;

-- Only live workspaces are readable; deleted ones come from
-- my_deleted_workspaces().
drop policy workspaces_read on public.workspaces;
create policy workspaces_read on public.workspaces for select to authenticated
  using (deleted_at is null
         and (public.is_workspace_member(id) or public.is_company_owner(company_id)));

-- ---------------------------------------------------------------------------
-- Background jobs skip deleted workspaces.
-- ---------------------------------------------------------------------------

create or replace function public.process_task_reminders()
returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r    record;
  sent integer := 0;
begin
  for r in
    select tr.id, tr.kind, t.id as task_id, t.status, t.due_at, t.deleted_at, t.created_by,
           p.status as project_status, w.deleted_at as workspace_deleted_at
    from task_reminders tr
    join tasks t on t.id = tr.task_id
    join projects p on p.id = t.project_id
    join workspaces w on w.id = p.workspace_id
    where tr.sent_at is null and tr.remind_at <= now()
    order by tr.remind_at
    limit 1000
    for update of tr skip locked
  loop
    update task_reminders set sent_at = now() where id = r.id;
    continue when r.deleted_at is not null or r.status = 'done' or r.project_status <> 'active'
               or r.workspace_deleted_at is not null;

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

create or replace function public.process_recurring_tasks()
returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r    record;
  made integer := 0;
begin
  for r in
    select t.id from tasks t
    join workspaces w on w.id = t.workspace_id and w.deleted_at is null
    where t.repeat is not null and t.repeat_next is null and t.deleted_at is null
      and t.due_at <= now()
    order by t.due_at
    limit 500
  loop
    if public.spawn_next_task(r.id) is not null then
      made := made + 1;
    end if;
  end loop;
  return made;
end;
$$;

create or replace function public.process_subscriptions()
returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  w       record;
  changed integer := 0;
begin
  for w in
    select ws.id, p.name as plan_name, ws.paid_until from workspaces ws join plans p on p.id = ws.plan_id
    where ws.plan_id <> 'free' and ws.paid_until is not null and ws.deleted_at is null
      and ws.paid_until > now() and ws.paid_until <= now() + interval '7 days'
      and ws.ending_noticed_for is distinct from ws.paid_until
    for update of ws skip locked
  loop
    update workspaces set ending_noticed_for = w.paid_until where id = w.id;
    perform public.notify_billing(array[public.company_owner_of(w.id)], w.id, 'plan_ending',
                                  w.plan_name);
    changed := changed + 1;
  end loop;

  for w in
    select ws.id, p.name as plan_name, ws.deleted_at from workspaces ws join plans p on p.id = ws.plan_id
    where ws.plan_id <> 'free' and ws.paid_until is not null
      and ws.paid_until < now() - interval '7 days'
    for update of ws skip locked
  loop
    perform public.put_on_plan(w.id, 'free', null, 'expired');
    if w.deleted_at is null then
      perform public.notify_billing(array[public.company_owner_of(w.id)], w.id, 'plan_expired',
                                    w.plan_name);
    end if;
    changed := changed + 1;
  end loop;
  return changed;
end;
$$;

-- ---------------------------------------------------------------------------
-- Leaving, deleting and restoring
-- ---------------------------------------------------------------------------

-- Leaves a workspace. The last owner hands ownership over first (last_owner).
create function public.leave_workspace(p_workspace uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.is_workspace_member(p_workspace) then
    raise exception 'not_allowed';
  end if;
  update workspace_members set status = 'inactive'
  where workspace_id = p_workspace and user_id = auth.uid();
end;
$$;

-- Whether the signed-in user may delete or restore a workspace: one of its
-- active owners, or the owner of its company.
create function public.can_delete_workspace(p_workspace uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from workspaces w
    where w.id = p_workspace
      and (exists (select 1 from workspace_members wm
                   where wm.workspace_id = w.id and wm.user_id = auth.uid()
                     and wm.status = 'active' and wm.role = 'owner')
           or public.is_company_owner(w.company_id))
  );
$$;

-- Deletes a workspace once its name is typed back. Pending invites and join
-- requests are cancelled and it stops showing in search.
create function public.delete_workspace(p_workspace uuid, p_confirm_name text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  ws workspaces%rowtype;
begin
  select * into ws from workspaces where id = p_workspace and deleted_at is null for update;
  if ws.id is null or not public.can_delete_workspace(p_workspace) then
    raise exception 'not_allowed';
  end if;
  if coalesce(trim(p_confirm_name), '') <> trim(ws.name) then
    raise exception 'name_mismatch';
  end if;
  update workspaces
  set deleted_at = now(), deleted_by = auth.uid(), discoverable = false
  where id = p_workspace;
  update invites set status = 'cancelled'
  where workspace_id = p_workspace and status = 'pending';
  update join_requests set status = 'cancelled', decided_by = auth.uid(), decided_at = now()
  where workspace_id = p_workspace and status = 'pending';
end;
$$;

-- Deleted workspaces the signed-in user can still bring back.
create function public.my_deleted_workspaces()
returns table (id uuid, name text, company_name text, deleted_at timestamptz,
               purge_at timestamptz, deleted_by_name text)
language sql stable security definer set search_path = public, pg_temp as $$
  select w.id, w.name, c.name, w.deleted_at, w.deleted_at + interval '30 days', p.full_name
  from workspaces w
  join companies c on c.id = w.company_id
  left join profiles p on p.id = w.deleted_by
  where w.deleted_at is not null and public.can_delete_workspace(w.id)
  order by w.deleted_at desc;
$$;

create function public.restore_workspace(p_workspace uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not exists (select 1 from workspaces where id = p_workspace and deleted_at is not null)
     or not public.can_delete_workspace(p_workspace) then
    raise exception 'not_allowed';
  end if;
  update workspaces set deleted_at = null, deleted_by = null where id = p_workspace;
end;
$$;

-- Removes for good what was deleted more than 30 days ago.
create function public.purge_deleted_workspaces()
returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  n integer;
begin
  delete from workspaces where deleted_at < now() - interval '30 days';
  get diagnostics n = row_count;
  return n;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('wasla-purge-workspaces', '15 3 * * *',
                          'select public.purge_deleted_workspaces()');
  else
    raise notice 'pg_cron is not available here; deleted workspaces are not purged';
  end if;
end $$;

revoke execute on function
  public.leave_workspace(uuid),
  public.can_delete_workspace(uuid),
  public.delete_workspace(uuid, text),
  public.my_deleted_workspaces(),
  public.restore_workspace(uuid),
  public.purge_deleted_workspaces()
from public, anon, authenticated;

grant execute on function
  public.leave_workspace(uuid),
  public.can_delete_workspace(uuid),
  public.delete_workspace(uuid, text),
  public.my_deleted_workspaces(),
  public.restore_workspace(uuid)
to authenticated;
