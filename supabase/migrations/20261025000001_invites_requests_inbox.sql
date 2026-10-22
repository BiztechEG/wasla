-- Invitations and join requests reach people through the bell and the phone,
-- like everything else that needs an answer.
--
-- * Someone invited by email or phone hears of it at once if they already
--   have an account, or as soon as they sign up.
-- * A workspace's owners and admins hear of each request to join.
-- * The person asking hears whether they were accepted; the admin who sent
--   an invitation hears when it is accepted.
-- * Once an invitation or request is answered, withdrawn or cancelled, its
--   notifications count as read for everyone, so no badge waits on something
--   already done.
-- * my_notifications() says where each invitation or request stands, so the
--   app offers Accept and Decline only while it is still open.

alter table public.notifications
  add column invite_id       uuid references public.invites (id) on delete cascade,
  add column join_request_id uuid references public.join_requests (id) on delete cascade;

create index notifications_invite_idx on public.notifications (invite_id)
  where invite_id is not null;
create index notifications_join_request_idx on public.notifications (join_request_id)
  where join_request_id is not null;

alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('assigned', 'status', 'comment', 'due_changed', 'nudge',
                  'due_soon', 'overdue', 'reminder', 'unassigned', 'deleted',
                  'plan_request', 'invoice', 'plan_active', 'plan_ending', 'plan_expired',
                  'invite', 'invite_accepted', 'join_request',
                  'request_accepted', 'request_declined'));

-- ---------------------------------------------------------------------------
-- Invitations
-- ---------------------------------------------------------------------------

-- Tells the people an invitation is addressed to, unless they are already in.
create function public.notify_invite(p_invite uuid, p_only uuid default null)
returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into notifications (user_id, workspace_id, kind, actor_id, detail, invite_id)
  select p.id, i.workspace_id, 'invite', i.invited_by, i.role::text, i.id
  from invites i
  join profiles p
    on (i.email is not null and lower(p.email) = lower(i.email))
    or (i.phone is not null and p.phone = i.phone)
  where i.id = p_invite and i.status = 'pending' and i.expires_at > now()
    and (p_only is null or p.id = p_only)
    and p.id is distinct from i.invited_by
    and not exists (select 1 from workspace_members wm
                    where wm.workspace_id = i.workspace_id and wm.user_id = p.id
                      and wm.status = 'active');
$$;

create function public.invites_notify_new()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.notify_invite(new.id);
  return null;
end;
$$;

create trigger invites_notify_new after insert on public.invites
  for each row execute function public.invites_notify_new();

-- Someone who signs up after being invited finds the invitation waiting.
create function public.profiles_notify_invites()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  i uuid;
begin
  for i in
    select id from invites
    where status = 'pending' and expires_at > now()
      and ((email is not null and lower(email) = lower(new.email))
        or (phone is not null and phone = new.phone))
  loop
    perform public.notify_invite(i, new.id);
  end loop;
  return null;
end;
$$;

create trigger profiles_notify_invites after insert on public.profiles
  for each row execute function public.profiles_notify_invites();

create function public.invites_notify_answer()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update notifications set read_at = clock_timestamp()
  where invite_id = new.id and kind = 'invite' and read_at is null;

  if new.status = 'accepted' and auth.uid() is distinct from new.invited_by then
    insert into notifications (user_id, workspace_id, kind, actor_id, detail, invite_id)
    values (new.invited_by, new.workspace_id, 'invite_accepted', auth.uid(),
            new.role::text, new.id);
  end if;
  return null;
end;
$$;

create trigger invites_notify_answer after update of status on public.invites
  for each row when (old.status = 'pending' and new.status <> 'pending')
  execute function public.invites_notify_answer();

-- ---------------------------------------------------------------------------
-- Join requests
-- ---------------------------------------------------------------------------

create function public.join_requests_notify_new()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into notifications (user_id, workspace_id, kind, actor_id, detail, join_request_id)
  select wm.user_id, new.workspace_id, 'join_request', new.user_id,
         left(new.message, 200), new.id
  from workspace_members wm
  where wm.workspace_id = new.workspace_id and wm.status = 'active'
    and wm.role in ('owner', 'admin') and wm.user_id <> new.user_id;
  return null;
end;
$$;

create trigger join_requests_notify_new after insert on public.join_requests
  for each row execute function public.join_requests_notify_new();

create function public.join_requests_notify_answer()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  -- One admin's answer settles it for all of them.
  update notifications set read_at = clock_timestamp()
  where join_request_id = new.id and kind = 'join_request' and read_at is null;

  if new.status in ('accepted', 'rejected') then
    insert into notifications (user_id, workspace_id, kind, actor_id, join_request_id)
    values (new.user_id, new.workspace_id,
            case when new.status = 'accepted' then 'request_accepted' else 'request_declined' end,
            new.decided_by, new.id);
  end if;
  return null;
end;
$$;

create trigger join_requests_notify_answer after update of status on public.join_requests
  for each row when (old.status = 'pending' and new.status <> 'pending')
  execute function public.join_requests_notify_answer();

-- ---------------------------------------------------------------------------
-- What the bell shows
-- ---------------------------------------------------------------------------

-- request_status: where the invitation or request stands now ('pending',
-- 'accepted', 'rejected', 'cancelled' or 'expired'); null for other kinds.
drop function public.my_notifications(integer);
create function public.my_notifications(p_limit integer default 50)
returns table (
  id uuid, kind text, task_id uuid, task_title text,
  project_name text, project_color text, workspace_id uuid, workspace_name text,
  actor_name text, detail text, created_at timestamptz, read_at timestamptz,
  invite_id uuid, join_request_id uuid, request_status text
)
language sql stable security definer set search_path = public, pg_temp as $$
  select n.id, n.kind, n.task_id,
         case when n.kind in ('unassigned', 'deleted') then coalesce(n.detail, t.title)
              else t.title end,
         p.name, p.color, n.workspace_id, w.name,
         a.full_name, n.detail, n.created_at, n.read_at,
         n.invite_id, n.join_request_id,
         case when i.id is not null then
                case when i.status = 'pending' and i.expires_at <= now() then 'expired'
                     else i.status::text end
              when jr.id is not null then jr.status::text end
  from notifications n
  join workspaces w on w.id = n.workspace_id and w.deleted_at is null
  left join tasks t on t.id = n.task_id
  left join projects p on p.id = t.project_id
  left join profiles a on a.id = n.actor_id
  left join invites i on i.id = n.invite_id
  left join join_requests jr on jr.id = n.join_request_id
  where n.user_id = auth.uid()
    and (n.task_id is null or n.kind in ('unassigned', 'deleted')
         or public.can_see_task(n.task_id))
  order by n.created_at desc
  limit least(greatest(coalesce(p_limit, 50), 1), 100);
$$;

-- ---------------------------------------------------------------------------
-- Phones: a tap opens the place to answer.
-- ---------------------------------------------------------------------------

create or replace function public.push_notification()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  actor text;
  title text;
begin
  select full_name into actor from profiles where id = new.actor_id;
  if new.task_id is not null then
    select tk.title into title from tasks tk where tk.id = new.task_id;
  else
    select name into title from workspaces where id = new.workspace_id;
  end if;
  perform public.queue_push(array[new.user_id], new.workspace_id, new.kind, title, actor,
    new.detail,
    jsonb_build_object(
      'type', case when new.task_id is not null and new.kind <> 'deleted' then 'task'
                   when new.kind = 'plan_request' then 'admin'
                   when new.kind = 'invite' then 'invites'
                   when new.kind = 'join_request' then 'join_requests'
                   when new.kind = 'invite_accepted' then 'members'
                   when new.kind = 'request_accepted' then 'workspace'
                   when new.kind = 'request_declined' then 'notifications'
                   when new.task_id is null then 'billing'
                   else 'notifications' end,
      'task', new.task_id,
      'request', coalesce(new.invite_id, new.join_request_id)));
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------------

revoke execute on function
  public.notify_invite(uuid, uuid),
  public.invites_notify_new(),
  public.profiles_notify_invites(),
  public.invites_notify_answer(),
  public.join_requests_notify_new(),
  public.join_requests_notify_answer(),
  public.my_notifications(integer)
from public, anon, authenticated;

grant execute on function public.my_notifications(integer) to authenticated;
