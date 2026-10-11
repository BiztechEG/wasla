-- Wasla: phone notifications and file cleanup.
--
-- * The app registers each phone's Firebase Cloud Messaging token, with the
--   language its notifications are written in (push_tokens).
-- * New chat messages, announcements and in-app notifications (tasks,
--   reminders, billing) queue a phone notification for each person who has a
--   phone registered (push_outbox). The Edge Function `push` sends them; the
--   database calls it right away through pg_net, and pg_cron calls it every
--   minute to retry.
-- * Each night the Edge Function `cleanup` removes from storage the files
--   nobody can reach any more: deleted messages, project files and tasks, and
--   uploads that were never sent. They stop counting against the plan.
--
-- The Edge Functions prove who they are with the key in push_config, which
-- only the database and the functions (through the server key) can read.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.push_tokens (
  token      text primary key check (length(token) between 20 and 4096),
  user_id    uuid not null references public.profiles (id) on delete cascade,
  platform   text not null check (platform in ('android', 'ios', 'web')),
  locale     text not null default 'ar' check (locale in ('ar', 'en')),
  updated_at timestamptz not null default now()
);

create index push_tokens_user_idx on public.push_tokens (user_id);

-- kind: 'message', 'announcement', or a notifications.kind.
create table public.push_outbox (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references public.profiles (id) on delete cascade,
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  kind         text not null,
  title        text,                       -- chat, project, task or workspace name
  actor        text,                       -- who did it
  body         text,                       -- message, announcement or detail
  data         jsonb not null default '{}', -- what the app opens on a tap
  created_at   timestamptz not null default clock_timestamp(),
  attempts     integer not null default 0,
  claimed_at   timestamptz,
  sent_at      timestamptz
);

create index push_outbox_pending_idx on public.push_outbox (id) where sent_at is null;

-- One row. base_url is where the Edge Functions answer; it stays empty where
-- pg_net is missing (the test server), so nothing is called there. When the
-- database moves to its own server, set it to that server's functions URL.
create table public.push_config (
  id       boolean primary key default true check (id),
  base_url text,
  key      text not null
           default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
);

insert into public.push_config default values;

-- When a deleted file's stored copy was removed.
alter table public.files add column purged_at timestamptz;

-- ---------------------------------------------------------------------------
-- Phones
-- ---------------------------------------------------------------------------

-- Called by the app at every start and when the language changes. A phone
-- that signs in to another account moves to it. Ten phones per person.
create function public.register_push_token(p_token text, p_platform text, p_locale text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'not_allowed';
  end if;
  insert into push_tokens (token, user_id, platform, locale, updated_at)
  values (p_token, me, p_platform, coalesce(p_locale, 'ar'), clock_timestamp())
  on conflict (token) do update
    set user_id = excluded.user_id, platform = excluded.platform,
        locale = excluded.locale, updated_at = excluded.updated_at;
  delete from push_tokens
  where user_id = me
    and token not in (select token from push_tokens where user_id = me
                      order by updated_at desc limit 10);
end;
$$;

-- Called on sign-out, so the phone stops getting this account's news.
create function public.unregister_push_token(p_token text)
returns void
language sql security definer set search_path = public, pg_temp as $$
  delete from push_tokens where token = p_token and user_id = auth.uid();
$$;

-- ---------------------------------------------------------------------------
-- Queueing
-- ---------------------------------------------------------------------------

-- Queues one notification for each of p_users who has a phone registered.
create function public.queue_push(
  p_users uuid[], p_workspace uuid, p_kind text,
  p_title text, p_actor text, p_body text, p_data jsonb
) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into push_outbox (user_id, workspace_id, kind, title, actor, body, data)
  select u, p_workspace, p_kind, left(p_title, 200), left(p_actor, 200), left(p_body, 300),
         p_data || jsonb_build_object('workspace', p_workspace)
  from (select distinct u from unnest(p_users) u where u is not null) x
  where exists (select 1 from push_tokens t where t.user_id = x.u);
$$;

-- A chat message: the other person of a private chat, or the project's
-- members, apart from the sender.
create function public.push_message()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  cv     conversations%rowtype;
  sender text;
  title  text;
  body   text := new.body;
  people uuid[];
begin
  if new.deleted_at is not null then
    return null;
  end if;
  select * into cv from conversations where id = new.conversation_id;
  select full_name into sender from profiles where id = new.sender_id;
  if body is null and new.file_id is not null then
    select '📎 ' || name into body from files where id = new.file_id;
  end if;

  if cv.kind = 'direct' then
    people := array(
      select wm.user_id from workspace_members wm
      where wm.workspace_id = cv.workspace_id and wm.status = 'active'
        and wm.user_id = case when cv.user_a = new.sender_id then cv.user_b else cv.user_a end);
    title := sender;
  else
    select name into title from projects where id = cv.project_id;
    people := array(
      select pm.user_id from project_members pm
      where pm.project_id = cv.project_id and pm.user_id <> new.sender_id
        and public.user_sees_project(pm.user_id, cv.project_id));
  end if;

  perform public.queue_push(people, cv.workspace_id, 'message', title, sender, body,
    jsonb_build_object('type', 'chat', 'conversation', cv.id, 'direct', cv.kind = 'direct'));
  return null;
end;
$$;

create trigger messages_push after insert on public.messages
  for each row execute function public.push_message();

create function public.push_announcement()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  author text;
  title  text;
begin
  select full_name into author from profiles where id = new.created_by;
  if new.project_id is null then
    select name into title from workspaces where id = new.workspace_id;
  else
    select name into title from projects where id = new.project_id;
  end if;
  perform public.queue_push(
    array(select user_id from public.announcement_audience(new.id) where user_id <> new.created_by),
    new.workspace_id, 'announcement', title, author, new.body,
    jsonb_build_object('type', 'announcement', 'project', new.project_id));
  return null;
end;
$$;

create trigger announcements_push after insert on public.announcements
  for each row execute function public.push_announcement();

-- Everything the bell shows (tasks, reminders, billing) also reaches the phone.
create function public.push_notification()
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
                   when new.task_id is null then 'billing'
                   else 'notifications' end,
      'task', new.task_id));
  return null;
end;
$$;

create trigger notifications_push after insert on public.notifications
  for each row execute function public.push_notification();

-- ---------------------------------------------------------------------------
-- Calling the Edge Functions
-- ---------------------------------------------------------------------------

-- Asks Edge Function p_name to run. Never gets in the way of what queued it.
create function public.call_edge(p_name text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  c push_config%rowtype;
begin
  select * into c from push_config;
  if c.base_url is null or not exists (select 1 from pg_extension where extname = 'pg_net') then
    return;
  end if;
  perform net.http_post(
    url := c.base_url || '/' || p_name,
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-wasla-key', c.key),
    timeout_milliseconds := 30000);
exception when others then
  raise warning 'could not call %: %', p_name, sqlerrm;
end;
$$;

create function public.push_outbox_kick()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.call_edge('push');
  return null;
end;
$$;

create trigger push_outbox_kick after insert on public.push_outbox
  for each statement execute function public.push_outbox_kick();

create function public.check_edge_key(p_key text)
returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if p_key is null or p_key is distinct from (select key from push_config) then
    raise exception 'not_allowed';
  end if;
end;
$$;

-- For the push function: takes up to p_limit queued notifications, one row
-- per phone (token is null when the person has none left). Notifications
-- older than an hour are dropped rather than sent late; each is tried three
-- times at most, two minutes apart.
create function public.claim_push_batch(p_key text, p_limit integer default 500)
returns table (id bigint, token text, locale text, kind text,
               title text, actor text, body text, data jsonb)
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.check_edge_key(p_key);
  return query
  with picked as (
    select o.id from push_outbox o
    where o.sent_at is null and o.attempts < 3
      and o.created_at > now() - interval '1 hour'
      and (o.claimed_at is null or o.claimed_at < now() - interval '2 minutes')
    order by o.id
    limit least(greatest(p_limit, 1), 1000)
    for update skip locked
  ), claimed as (
    update push_outbox o set attempts = o.attempts + 1, claimed_at = now()
    from picked where o.id = picked.id
    returning o.*
  )
  select c.id, t.token, t.locale, c.kind, c.title, c.actor, c.body, c.data
  from claimed c left join push_tokens t on t.user_id = c.user_id
  order by c.id;
end;
$$;

-- For the push function: marks notifications done and forgets phones that
-- Firebase says are gone.
create function public.finish_push_batch(p_key text, p_ids bigint[], p_bad_tokens text[])
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.check_edge_key(p_key);
  update push_outbox set sent_at = now() where id = any (p_ids) and sent_at is null;
  delete from push_tokens where token = any (p_bad_tokens);
end;
$$;

-- Every minute: retries what is waiting, and forgets old notifications and
-- phones not seen for 90 days.
create function public.push_tick()
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  delete from push_outbox where created_at < now() - interval '3 days';
  delete from push_tokens where updated_at < now() - interval '90 days';
  if exists (select 1 from push_outbox
             where sent_at is null and attempts < 3
               and created_at > now() - interval '1 hour'
               and (claimed_at is null or claimed_at < now() - interval '2 minutes')) then
    perform public.call_edge('push');
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- File cleanup
-- ---------------------------------------------------------------------------

-- For the cleanup function: stored files to remove. Files deleted more than
-- a day ago, and uploads more than a day old that no file record uses (a
-- send that failed, or a workspace that was deleted).
create function public.files_to_purge(p_key text, p_limit integer default 500)
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
     and not exists (select 1 from files f where f.storage_path = o.name))
  limit least(greatest(p_limit, 1), 1000);
end;
$$;

create function public.mark_files_purged(p_key text, p_paths text[])
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.check_edge_key(p_key);
  update files set purged_at = now()
  where storage_path = any (p_paths) and deleted_at is not null and purged_at is null;
end;
$$;

-- ---------------------------------------------------------------------------
-- Scheduling, where Supabase's pg_net and pg_cron are available.
-- ---------------------------------------------------------------------------

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    if not exists (select 1 from pg_extension where extname = 'pg_net') then
      create extension pg_net with schema extensions;
    end if;
    update public.push_config
    set base_url = 'https://qbefpiuglhsgcgwsaocn.supabase.co/functions/v1'
    where base_url is null;
  else
    raise notice 'pg_net is not available here; phone notifications are not sent';
  end if;

  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    -- Already turned on by the tasks migration; see the billing migration
    -- for why it is never created again.
    if not exists (select 1 from pg_extension where extname = 'pg_cron') then
      create extension pg_cron with schema pg_catalog;
    end if;
    perform cron.schedule('wasla-push', '* * * * *', 'select public.push_tick()');
    perform cron.schedule('wasla-file-cleanup', '30 2 * * *',
                          $job$select public.call_edge('cleanup')$job$);
  else
    raise notice 'pg_cron is not available here; push retries and file cleanup are not scheduled';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Privileges: the tables are reached only through the functions above.
-- ---------------------------------------------------------------------------

alter table public.push_tokens enable row level security;
alter table public.push_outbox enable row level security;
alter table public.push_config enable row level security;

revoke all on public.push_tokens, public.push_outbox, public.push_config
from anon, authenticated;

revoke execute on function
  public.register_push_token(text, text, text),
  public.unregister_push_token(text),
  public.queue_push(uuid[], uuid, text, text, text, text, jsonb),
  public.push_message(),
  public.push_announcement(),
  public.push_notification(),
  public.call_edge(text),
  public.push_outbox_kick(),
  public.check_edge_key(text),
  public.claim_push_batch(text, integer),
  public.finish_push_batch(text, bigint[], text[]),
  public.push_tick(),
  public.files_to_purge(text, integer),
  public.mark_files_purged(text, text[])
from public, anon, authenticated;

grant execute on function
  public.register_push_token(text, text, text),
  public.unregister_push_token(text)
to authenticated;

-- The Edge Functions call in with the server key.
grant execute on function
  public.claim_push_batch(text, integer),
  public.finish_push_batch(text, bigint[], text[]),
  public.files_to_purge(text, integer),
  public.mark_files_purged(text, text[])
to service_role;
