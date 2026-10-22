-- Control over phone notifications.
--
-- * Muting a chat (for a while, or until unmuted) stops its messages from
--   reaching one's phone. Mentions still come through, and the chat still
--   shows its unread count in the app.
-- * Quiet hours: between two times of day (in the phone's time zone, as an
--   offset from UTC), nothing reaches the phone. The bell and the app's
--   counts still have everything.
-- * Both are applied where every phone notification is queued (queue_push),
--   so chats, tasks, announcements and attendance all follow them.

create table public.conversation_mutes (
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  user_id         uuid not null references public.profiles (id) on delete cascade,
  until           timestamptz,
  primary key (conversation_id, user_id)
);

create index conversation_mutes_user_idx on public.conversation_mutes (user_id);

create table public.notification_settings (
  user_id     uuid primary key references public.profiles (id) on delete cascade,
  quiet_from  time,
  quiet_to    time,
  -- Minutes east of UTC where the phone is.
  utc_offset  integer not null default 120 check (utc_offset between -720 and 840),
  check ((quiet_from is null) = (quiet_to is null))
);

alter table public.conversation_mutes enable row level security;
alter table public.notification_settings enable row level security;
revoke all on public.conversation_mutes, public.notification_settings from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Muting chats
-- ---------------------------------------------------------------------------

-- Mutes a chat one is in until p_until (null: until unmuted).
create function public.mute_conversation(p_conversation uuid, p_until timestamptz default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.can_read_conversation(p_conversation) then
    raise exception 'not_allowed';
  end if;
  if p_until is not null and p_until <= now() then
    raise exception 'invalid_date';
  end if;
  insert into conversation_mutes (conversation_id, user_id, until)
  values (p_conversation, auth.uid(), p_until)
  on conflict (conversation_id, user_id) do update set until = excluded.until;
end;
$$;

create function public.unmute_conversation(p_conversation uuid)
returns void
language sql security definer set search_path = public, pg_temp as $$
  delete from conversation_mutes where conversation_id = p_conversation and user_id = auth.uid();
$$;

-- The chats one has muted in a workspace, and until when.
create function public.my_muted_conversations(p_workspace uuid)
returns table (conversation_id uuid, until timestamptz)
language sql stable security definer set search_path = public, pg_temp as $$
  select m.conversation_id, m.until
  from conversation_mutes m
  join conversations c on c.id = m.conversation_id and c.workspace_id = p_workspace
  where m.user_id = auth.uid() and (m.until is null or m.until > now());
$$;

-- ---------------------------------------------------------------------------
-- Quiet hours
-- ---------------------------------------------------------------------------

create function public.my_notification_settings()
returns table (quiet_from time, quiet_to time, utc_offset integer)
language sql stable security definer set search_path = public, pg_temp as $$
  select s.quiet_from, s.quiet_to, s.utc_offset
  from notification_settings s where s.user_id = auth.uid();
$$;

-- Sets (or with nulls turns off) quiet hours; the app also calls it when the
-- phone's offset from UTC changes.
create function public.set_quiet_hours(p_from time, p_to time, p_utc_offset integer)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null or (p_from is null) <> (p_to is null) or p_from = p_to
     or p_utc_offset not between -720 and 840 then
    raise exception 'invalid_hours';
  end if;
  insert into notification_settings (user_id, quiet_from, quiet_to, utc_offset)
  values (auth.uid(), p_from, p_to, p_utc_offset)
  on conflict (user_id) do update
    set quiet_from = excluded.quiet_from, quiet_to = excluded.quiet_to,
        utc_offset = excluded.utc_offset;
end;
$$;

-- Whether [u]'s quiet hours are on now. Hours past midnight (22:00 to 07:00)
-- wrap around.
create function public.in_quiet_hours(u uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((
    select case when s.quiet_from < s.quiet_to then t >= s.quiet_from and t < s.quiet_to
                else t >= s.quiet_from or t < s.quiet_to end
    from notification_settings s,
         lateral (select ((now() at time zone 'UTC') + make_interval(mins => s.utc_offset))::time as t) local
    where s.user_id = u and s.quiet_from is not null
  ), false);
$$;

-- ---------------------------------------------------------------------------
-- Queueing follows both
-- ---------------------------------------------------------------------------

create or replace function public.queue_push(
  p_users uuid[], p_workspace uuid, p_kind text,
  p_title text, p_actor text, p_body text, p_data jsonb
) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into push_outbox (user_id, workspace_id, kind, title, actor, body, data)
  select u, p_workspace, p_kind, left(p_title, 200), left(p_actor, 200), left(p_body, 300),
         p_data || jsonb_build_object('workspace', p_workspace)
  from (select distinct u from unnest(p_users) u where u is not null) x
  where exists (select 1 from push_tokens t where t.user_id = x.u)
    and not public.in_quiet_hours(x.u)
    and not (p_kind = 'message' and exists (
      select 1 from conversation_mutes m
      where m.user_id = x.u and m.conversation_id::text = p_data ->> 'conversation'
        and (m.until is null or m.until > now())));
$$;

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------

revoke execute on function
  public.mute_conversation(uuid, timestamptz),
  public.unmute_conversation(uuid),
  public.my_muted_conversations(uuid),
  public.my_notification_settings(),
  public.set_quiet_hours(time, time, integer),
  public.in_quiet_hours(uuid),
  public.queue_push(uuid[], uuid, text, text, text, text, jsonb)
from public, anon, authenticated;

grant execute on function
  public.mute_conversation(uuid, timestamptz),
  public.unmute_conversation(uuid),
  public.my_muted_conversations(uuid),
  public.my_notification_settings(),
  public.set_quiet_hours(time, time, integer)
to authenticated;
