-- Wasla: @mentions and emoji reactions in chats.
--
-- * A message names the people it mentions (messages.mentions). They must
--   be able to read the chat; anyone else is dropped. Each one gets a
--   "mentioned you" phone notification instead of the usual one, and the
--   chat list counts unread mentions.
-- * Reactions live on the message itself (emoji -> the people who chose it),
--   so changing one updates the message and reaches open chats through the
--   live updates they already follow.

alter table public.messages
  add column mentions  uuid[],
  add column reactions jsonb not null default '{}'::jsonb;

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------

drop function public.send_message(uuid, text, uuid, uuid, text, text, text, bigint);

create function public.send_message(
  p_conversation uuid,
  p_body         text   default null,
  p_reply_to     uuid   default null,
  p_project      uuid   default null,
  p_file_path    text   default null,
  p_file_name    text   default null,
  p_file_mime    text   default null,
  p_file_size    bigint default null,
  p_mentions     uuid[] default null
) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me    uuid := auth.uid();
  cv    conversations%rowtype;
  other uuid;
  tag   uuid;
  f     uuid;
  m     uuid;
  sent  timestamptz;
  named uuid[];
begin
  select * into cv from conversations where id = p_conversation;
  if cv.id is null or not public.can_read_conversation(cv.id) then
    raise exception 'not_allowed';
  end if;

  p_body := nullif(trim(p_body), '');
  if p_body is null and p_file_path is null then
    raise exception 'empty_message';
  end if;

  -- One send at a time per person, so the limit holds for parallel calls.
  perform pg_advisory_xact_lock(hashtext('wasla_send:' || me::text));
  if (select count(*) from messages
      where sender_id = me and created_at > now() - interval '1 minute') >= 60 then
    raise exception 'too_many_requests';
  end if;

  if cv.kind = 'project' then
    if (select status from projects where id = cv.project_id) <> 'active' then
      raise exception 'conversation_closed';
    end if;
    tag := cv.project_id;
  else
    other := case when cv.user_a = me then cv.user_b else cv.user_a end;
    if not exists (select 1 from workspace_members
                   where workspace_id = cv.workspace_id and user_id = other and status = 'active') then
      raise exception 'conversation_closed';
    end if;
    if p_project is not null then
      if not exists (select 1 from projects
                     where id = p_project and workspace_id = cv.workspace_id and status = 'active')
         or not public.user_sees_project(me, p_project)
         or not public.user_sees_project(other, p_project) then
        raise exception 'invalid_project';
      end if;
      tag := p_project;
    end if;
  end if;

  if p_reply_to is not null
     and not exists (select 1 from messages where id = p_reply_to and conversation_id = cv.id) then
    raise exception 'invalid_reply';
  end if;

  -- Only people who can read the chat, never oneself.
  if p_mentions is not null then
    named := array(
      select distinct u from unnest(p_mentions) u
      where u <> me
        and case when cv.kind = 'direct' then u = other
                 else exists (select 1 from project_members pm
                              where pm.project_id = cv.project_id and pm.user_id = u)
                      and public.user_sees_project(u, cv.project_id) end
      limit 100);
    if cardinality(named) = 0 then
      named := null;
    end if;
  end if;

  if p_file_path is not null then
    f := public.store_file(cv.workspace_id, tag, cv.id, p_file_path,
                           p_file_name, p_file_mime, p_file_size);
  end if;

  insert into messages (conversation_id, workspace_id, sender_id, body, project_id, file_id,
                        reply_to, mentions)
  values (cv.id, cv.workspace_id, me, p_body, tag, f, p_reply_to, named)
  returning id, created_at into m, sent;

  update conversations set last_message_at = greatest(last_message_at, sent) where id = cv.id;

  -- Sending a message means having read the chat up to it.
  insert into conversation_reads (conversation_id, user_id, last_read_at)
  values (cv.id, me, sent)
  on conflict (conversation_id, user_id)
  do update set last_read_at = greatest(conversation_reads.last_read_at, excluded.last_read_at);

  return m;
end;
$$;

-- People mentioned are told they were, instead of getting the plain message.
create or replace function public.push_message()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  cv     conversations%rowtype;
  sender text;
  title  text;
  body   text := new.body;
  people uuid[];
  named  uuid[];
  data   jsonb;
begin
  if new.deleted_at is not null then
    return null;
  end if;
  select * into cv from conversations where id = new.conversation_id;
  select full_name into sender from profiles where id = new.sender_id;
  if body is null and new.file_id is not null then
    -- Voice messages are named voice_<seconds>s.<ext>: show a microphone
    -- and their length rather than the file name.
    select case when mime like 'audio/%' and name ~ '^voice_[0-9]+s\.[a-z0-9]+$'
                then '🎤 ' || (substring(name from '^voice_([0-9]+)s')::int / 60)::text || ':'
                     || lpad((substring(name from '^voice_([0-9]+)s')::int % 60)::text, 2, '0')
                else '📎 ' || name end
      into body from files where id = new.file_id;
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

  named := array(select u from unnest(people) u where u = any(coalesce(new.mentions, '{}')));
  data := jsonb_build_object('type', 'chat', 'conversation', cv.id, 'direct', cv.kind = 'direct');
  perform public.queue_push(
    array(select u from unnest(people) u where not u = any(named)),
    cv.workspace_id, 'message', title, sender, body, data);
  perform public.queue_push(named, cv.workspace_id, 'mention', title, sender, body, data);
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- Reactions
-- ---------------------------------------------------------------------------

-- Adds the signed-in user's reaction, or takes it back if it is there.
create function public.toggle_reaction(p_message uuid, p_emoji text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me     uuid := auth.uid();
  m      messages%rowtype;
  users  jsonb;
begin
  if p_emoji is null or length(p_emoji) not between 1 and 16 or p_emoji ~ '[[:space:]]' then
    raise exception 'invalid_reaction';
  end if;
  select * into m from messages where id = p_message for update;
  if m.id is null or m.deleted_at is not null
     or not public.can_read_conversation(m.conversation_id) then
    raise exception 'not_allowed';
  end if;
  if not public.project_is_open(
       (select project_id from conversations where id = m.conversation_id)) then
    raise exception 'conversation_closed';
  end if;

  users := coalesce(m.reactions -> p_emoji, '[]'::jsonb);
  if users ? me::text then
    users := users - me::text;
  else
    if not m.reactions ? p_emoji
       and (select count(*) from jsonb_object_keys(m.reactions)) >= 20 then
      raise exception 'too_many_reactions';
    end if;
    users := users || to_jsonb(me::text);
  end if;

  update messages
  set reactions = case when jsonb_array_length(users) = 0 then m.reactions - p_emoji
                       else jsonb_set(m.reactions, array[p_emoji], users) end
  where id = m.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------

drop function public.conversation_messages(uuid, timestamptz, timestamptz, uuid, integer);

-- Newest first. p_before pages back; p_after fetches what arrived since.
create function public.conversation_messages(
  p_conversation uuid,
  p_before       timestamptz default null,
  p_after        timestamptz default null,
  p_project      uuid        default null,
  p_limit        integer     default 50
) returns table (
  id uuid, sender_id uuid, sender_name text, body text, project_id uuid,
  created_at timestamptz, deleted boolean,
  reply_to uuid, reply_sender_name text, reply_body text, reply_file_name text,
  file_id uuid, file_name text, file_mime text, file_size bigint, file_path text,
  mentions uuid[], reactions jsonb
)
language sql stable security definer set search_path = public, pg_temp as $$
  select m.id, m.sender_id, s.full_name, m.body, m.project_id,
         m.created_at, m.deleted_at is not null,
         m.reply_to, rs.full_name,
         case when r.deleted_at is null then r.body end,
         case when r.deleted_at is null then rf.name end,
         f.id, f.name, f.mime, f.size_bytes, f.storage_path,
         case when m.deleted_at is null then m.mentions end,
         case when m.deleted_at is null then m.reactions else '{}'::jsonb end
  from messages m
  join profiles s       on s.id = m.sender_id
  left join files f     on f.id = m.file_id and m.deleted_at is null
  left join messages r  on r.id = m.reply_to
  left join profiles rs on rs.id = r.sender_id
  left join files rf    on rf.id = r.file_id
  where m.conversation_id = p_conversation
    and public.can_read_conversation(p_conversation)
    and (p_project is null or m.project_id = p_project)
    and (p_before is null or m.created_at < p_before)
    and (p_after is null or m.created_at > p_after)
  order by m.created_at desc
  limit least(greatest(coalesce(p_limit, 50), 1), 200);
$$;

drop function public.my_conversations(uuid);

-- The chat list: project chats one belongs to and private chats with
-- messages, latest first; with how many unread messages mention one.
create function public.my_conversations(p_workspace uuid)
returns table (
  id uuid, kind public.conversation_kind,
  project_id uuid, project_name text, project_color text,
  other_id uuid, other_name text, other_active boolean,
  last_at timestamptz, last_sender_id uuid, last_sender_name text,
  last_body text, last_file_name text, last_deleted boolean,
  unread integer, tag_project_ids uuid[], unread_mentions integer
)
language sql stable security definer set search_path = public, pg_temp as $$
  with mine as (
    select cv.*,
           case when cv.user_a = auth.uid() then cv.user_b else cv.user_a end as other
    from conversations cv
    left join projects pr on pr.id = cv.project_id
    where cv.workspace_id = p_workspace
      and public.is_workspace_member(p_workspace)
      and ((cv.kind = 'direct' and auth.uid() in (cv.user_a, cv.user_b)
            and cv.last_message_at is not null)
        or (cv.kind = 'project' and pr.status = 'active'
            and exists (select 1 from project_members pm
                        where pm.project_id = cv.project_id and pm.user_id = auth.uid())))
  )
  select cv.id, cv.kind,
         pr.id, pr.name, pr.color,
         o.id, o.full_name,
         case when cv.kind = 'direct' then coalesce(wm.status = 'active', false) else true end,
         lm.created_at, lm.sender_id, ls.full_name,
         lm.body, lf.name, lm.deleted_at is not null,
         (select count(*)::int from messages x
          where x.conversation_id = cv.id and x.sender_id <> auth.uid() and x.deleted_at is null
            and x.created_at > coalesce(rd.last_read_at, '-infinity')),
         case when cv.kind = 'direct' then
           array(select t.project_id
                 from (select distinct x.project_id from messages x
                       where x.conversation_id = cv.id and x.project_id is not null
                         and x.deleted_at is null) t
                 where public.can_see_project(t.project_id))
         else array[cv.project_id] end,
         (select count(*)::int from messages x
          where x.conversation_id = cv.id and x.deleted_at is null
            and auth.uid() = any(x.mentions)
            and x.created_at > coalesce(rd.last_read_at, '-infinity'))
  from mine cv
  left join projects pr          on pr.id = cv.project_id
  left join profiles o           on cv.kind = 'direct' and o.id = cv.other
  left join workspace_members wm on wm.workspace_id = cv.workspace_id and wm.user_id = o.id
  left join conversation_reads rd on rd.conversation_id = cv.id and rd.user_id = auth.uid()
  left join lateral (select * from messages x where x.conversation_id = cv.id
                     order by x.created_at desc limit 1) lm on true
  left join profiles ls on ls.id = lm.sender_id
  left join files lf    on lf.id = lm.file_id and lm.deleted_at is null
  order by coalesce(lm.created_at, cv.created_at) desc;
$$;

-- For someone's profile card: active projects in the workspace that both
-- the signed-in user and p_user are part of.
create function public.projects_with(p_workspace uuid, p_user uuid)
returns setof uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select pr.id from projects pr
  where pr.workspace_id = p_workspace and pr.status = 'active'
    and public.is_workspace_member(p_workspace)
    and exists (select 1 from project_members pm
                where pm.project_id = pr.id and pm.user_id = auth.uid())
    and exists (select 1 from project_members pm
                where pm.project_id = pr.id and pm.user_id = p_user)
  order by pr.name;
$$;

-- ---------------------------------------------------------------------------
-- Function privileges
-- ---------------------------------------------------------------------------

revoke execute on function
  public.send_message(uuid, text, uuid, uuid, text, text, text, bigint, uuid[]),
  public.toggle_reaction(uuid, text),
  public.conversation_messages(uuid, timestamptz, timestamptz, uuid, integer),
  public.my_conversations(uuid),
  public.projects_with(uuid, uuid)
from public, anon, authenticated;

grant execute on function
  public.send_message(uuid, text, uuid, uuid, text, text, text, bigint, uuid[]),
  public.toggle_reaction(uuid, text),
  public.conversation_messages(uuid, timestamptz, timestamptz, uuid, integer),
  public.my_conversations(uuid),
  public.projects_with(uuid, uuid)
to authenticated;
