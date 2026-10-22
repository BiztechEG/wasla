-- The weekly report: every Sunday morning, whoever runs a workspace (its
-- owners and admins, the company's owner) or a department gets how it went
-- last week, from the management dashboard's numbers: tasks done against
-- the week before, late, in review, and late arrivals.
--
-- * One notification per workspace (it opens the dashboard), and one email
--   with all of them, in the person's language.
-- * Anyone can turn it off in My account.

alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('assigned', 'status', 'comment', 'due_changed', 'nudge',
                  'due_soon', 'overdue', 'reminder', 'unassigned', 'deleted',
                  'plan_request', 'invoice', 'plan_active', 'plan_ending', 'plan_expired',
                  'invite', 'invite_accepted', 'join_request',
                  'request_accepted', 'request_declined', 'member_joined',
                  'weekly_report'));

alter table public.email_outbox drop constraint email_outbox_kind_check;
alter table public.email_outbox add constraint email_outbox_kind_check
  check (kind in ('invite', 'weekly_report'));

alter table public.notification_settings
  add column weekly_report boolean not null default true;

-- Late arrivals over the seven days before today (the report goes out on
-- Sunday morning: the week through Saturday) in a workspace with
-- attendance on.
create function public.late_arrivals_week(p_workspace uuid)
returns integer
language sql stable security definer set search_path = public, pg_temp as $$
  select count(*)::int from attendance_records r
  join attendance_settings st on st.workspace_id = r.workspace_id and st.enabled
  where r.workspace_id = p_workspace and r.late_minutes > 0
    and r.day >= (now() at time zone st.timezone)::date - 7
    and r.day < (now() at time zone st.timezone)::date;
$$;

-- Sends this week's reports; returns how many people got one.
create function public.send_weekly_reports()
returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  u     record;
  ov    jsonb;
  w     jsonb;
  rows  jsonb;
  late  integer;
  sent  integer := 0;
  was   text := current_setting('request.jwt.claim.sub', true);
begin
  for u in
    select p.id, p.email, p.locale
    from profiles p
    where not exists (select 1 from notification_settings s
                      where s.user_id = p.id and not s.weekly_report)
      and (exists (select 1 from workspace_members wm
                   join workspaces ws on ws.id = wm.workspace_id and ws.deleted_at is null
                   where wm.user_id = p.id and wm.status = 'active'
                     and wm.role in ('owner', 'admin'))
           or exists (select 1 from department_managers dm where dm.user_id = p.id)
           or exists (select 1 from companies c where c.owner_id = p.id))
  loop
    -- The dashboard's numbers, as this person sees them.
    perform set_config('request.jwt.claim.sub', u.id::text, true);
    ov := public.management_overview();
    rows := '[]';
    for w in select * from jsonb_array_elements(ov) loop
      -- Nothing to tell about an empty workspace.
      continue when (w ->> 'open')::int + (w ->> 'done_week')::int
                    + (w ->> 'done_week_before')::int = 0;
      late := case when w -> 'attendance' = 'null'::jsonb then null
                   else public.late_arrivals_week((w ->> 'workspace_id')::uuid) end;
      w := jsonb_build_object(
        'workspace', w ->> 'workspace_name',
        'done', (w ->> 'done_week')::int,
        'done_before', (w ->> 'done_week_before')::int,
        'late', (w ->> 'late')::int,
        'review', (w ->> 'review')::int,
        'open', (w ->> 'open')::int,
        'late_arrivals', late,
        'workspace_id', w ->> 'workspace_id');
      rows := rows || jsonb_build_array(w);
      insert into notifications (user_id, workspace_id, kind, detail)
      values (u.id, (w ->> 'workspace_id')::uuid, 'weekly_report', w::text);
    end loop;
    if jsonb_array_length(rows) > 0 then
      sent := sent + 1;
      if u.email is not null then
        insert into email_outbox (kind, to_email, locale, data)
        values ('weekly_report', u.email,
                case when u.locale = 'en' then 'en' else 'ar' end,
                jsonb_build_object('workspaces', rows));
      end if;
    end if;
  end loop;
  -- Whoever called is themselves again.
  perform set_config('request.jwt.claim.sub', coalesce(was, ''), true);
  return sent;
end;
$$;

-- Turning it on and off.
create function public.my_weekly_report()
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select weekly_report from notification_settings
                   where user_id = auth.uid()), true);
$$;

create function public.set_weekly_report(p_on boolean)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then
    raise exception 'not_allowed';
  end if;
  insert into notification_settings (user_id, weekly_report)
  values (auth.uid(), coalesce(p_on, true))
  on conflict (user_id) do update set weekly_report = excluded.weekly_report;
end;
$$;

-- Phones: a report opens the dashboard.
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
                   when new.kind in ('invite_accepted', 'member_joined') then 'members'
                   when new.kind = 'request_accepted' then 'workspace'
                   when new.kind = 'request_declined' then 'notifications'
                   when new.kind = 'weekly_report' then 'dashboard'
                   when new.task_id is null then 'billing'
                   else 'notifications' end,
      'task', new.task_id,
      'request', coalesce(new.invite_id, new.join_request_id)));
  return null;
end;
$$;

revoke execute on function
  public.late_arrivals_week(uuid),
  public.send_weekly_reports(),
  public.my_weekly_report(),
  public.set_weekly_report(boolean)
from public, anon, authenticated;
grant execute on function
  public.my_weekly_report(),
  public.set_weekly_report(boolean)
to authenticated;

-- Sundays at 06:00 UTC (08:00 or 09:00 in Cairo), the start of the week.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('wasla-weekly-report', '0 6 * * 0',
                          'select public.send_weekly_reports()');
  else
    raise notice 'pg_cron is not available here; weekly reports are not scheduled';
  end if;
end $$;
