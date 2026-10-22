-- Polls and pinned messages in chats.
--
-- * A poll is a message whose text is the question, with its options and
--   votes in messages.poll: {"options": [...], "multiple": bool,
--   "closed": bool, "votes": {"0": [user ids], ...}}. Being on the message,
--   votes reach everyone in the chat as it changes, like reactions.
-- * A chat has at most one pinned message, shown on top of it. In a private
--   chat either person pins; in a project's chat, whoever runs the project.

alter table public.messages add column poll jsonb;

alter table public.conversations
  add column pinned_message_id uuid references public.messages (id) on delete set null,
  add column pinned_by uuid references public.profiles (id) on delete set null,
  add column pinned_at timestamptz;

-- ---------------------------------------------------------------------------
-- Messages carry their poll
-- ---------------------------------------------------------------------------

drop function public.conversation_messages(uuid, timestamptz, timestamptz, uuid, integer);
drop function public.reply_chain(uuid);
drop function public.message_rows(uuid[]);

create function public.message_rows(p_ids uuid[])
returns table (
  id uuid, sender_id uuid, sender_name text, body text, project_id uuid,
  created_at timestamptz, deleted boolean,
  reply_to uuid, reply_sender_name text, reply_body text, reply_file_name text,
  file_id uuid, file_name text, file_mime text, file_size bigint, file_path text,
  mentions uuid[], reactions jsonb,
  file_from_files boolean, reply_count integer, repliers uuid[],
  poll jsonb
)
language sql stable security definer set search_path = public, pg_temp as $$
  select m.id, m.sender_id, s.full_name, m.body, m.project_id,
         m.created_at, m.deleted_at is not null,
         m.reply_to, rs.full_name,
         case when r.deleted_at is null then r.body end,
         case when r.deleted_at is null then rf.name end,
         f.id, f.name, f.mime, f.size_bytes, f.storage_path,
         case when m.deleted_at is null then m.mentions end,
         case when m.deleted_at is null then m.reactions else '{}'::jsonb end,
         coalesce(f.from_files, false),
         coalesce(ch.n, 0), coalesce(ch.people, '{}'),
         case when m.deleted_at is null then m.poll end
  from messages m
  join profiles s       on s.id = m.sender_id
  left join files f     on f.id = m.file_id and m.deleted_at is null
  left join messages r  on r.id = m.reply_to
  left join profiles rs on rs.id = r.sender_id
  left join files rf    on rf.id = r.file_id
  -- Only a message that is not itself a reply heads a chain.
  left join lateral (
    with recursive chain as (
      select x.id, x.sender_id, x.created_at, x.deleted_at
      from messages x where x.reply_to = m.id and m.reply_to is null
      union all
      select x.id, x.sender_id, x.created_at, x.deleted_at
      from messages x join chain c on x.reply_to = c.id
    )
    select count(*) filter (where deleted_at is null)::int as n,
           array(select t.sender_id from chain t where t.deleted_at is null
                 group by t.sender_id order by max(t.created_at) desc limit 3) as people
    from chain
  ) ch on true
  where m.id = any(p_ids);
$$;

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
  mentions uuid[], reactions jsonb,
  file_from_files boolean, reply_count integer, repliers uuid[],
  poll jsonb
)
language sql stable security definer set search_path = public, pg_temp as $$
  select r.* from public.message_rows(array(
    select m.id from messages m
    where m.conversation_id = p_conversation
      and public.can_read_conversation(p_conversation)
      and (p_project is null or m.project_id = p_project)
      and (p_before is null or m.created_at < p_before)
      and (p_after is null or m.created_at > p_after)
    order by m.created_at desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200))) r
  order by r.created_at desc;
$$;

-- A message and every reply under it (replies to replies included), oldest
-- first.
create function public.reply_chain(p_message uuid)
returns table (
  id uuid, sender_id uuid, sender_name text, body text, project_id uuid,
  created_at timestamptz, deleted boolean,
  reply_to uuid, reply_sender_name text, reply_body text, reply_file_name text,
  file_id uuid, file_name text, file_mime text, file_size bigint, file_path text,
  mentions uuid[], reactions jsonb,
  file_from_files boolean, reply_count integer, repliers uuid[],
  poll jsonb
)
language sql stable security definer set search_path = public, pg_temp as $$
  with recursive chain as (
    select x.id, x.created_at from messages x
    where x.id = p_message
      and public.can_read_conversation(x.conversation_id)
    union all
    select x.id, x.created_at from messages x join chain c on x.reply_to = c.id
  )
  select r.* from public.message_rows(array(
    select c.id from chain c order by c.created_at limit 500)) r
  order by r.created_at;
$$;

revoke execute on function public.message_rows(uuid[]) from public, anon, authenticated;
revoke execute on function
  public.conversation_messages(uuid, timestamptz, timestamptz, uuid, integer),
  public.reply_chain(uuid)
from public, anon;
grant execute on function
  public.conversation_messages(uuid, timestamptz, timestamptz, uuid, integer),
  public.reply_chain(uuid)
to authenticated;

-- ---------------------------------------------------------------------------
-- Polls
-- ---------------------------------------------------------------------------

-- Asks the chat a question with 2 to 10 options; [p_multiple]: more than one
-- may be picked.
create function public.create_poll(
  p_conversation uuid,
  p_question     text,
  p_options      text[],
  p_multiple     boolean default false,
  p_project      uuid    default null
) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  opts text[];
  m    uuid;
begin
  select array_agg(trim(o) order by n) into opts
  from unnest(p_options) with ordinality as x(o, n)
  where nullif(trim(o), '') is not null;
  if coalesce(cardinality(opts), 0) not between 2 and 10
     or exists (select 1 from unnest(opts) o where length(o) > 100)
     or nullif(trim(p_question), '') is null or length(p_question) > 300 then
    raise exception 'invalid_poll';
  end if;
  m := public.send_message(p_conversation, p_body => p_question, p_project => p_project);
  update messages
  set poll = jsonb_build_object('options', to_jsonb(opts),
                                'multiple', coalesce(p_multiple, false),
                                'closed', false, 'votes', '{}'::jsonb)
  where id = m;
  return m;
end;
$$;

-- One's answer: the options picked (by their place, from 0); none takes
-- it back.
create function public.vote_poll(p_message uuid, p_options integer[])
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  msg   messages%rowtype;
  me    text := auth.uid()::text;
  picks integer[] := array(select distinct x from unnest(coalesce(p_options, '{}')) x);
  votes jsonb := '{}';
  k     text;
begin
  select * into msg from messages where id = p_message for update;
  if msg.id is null or msg.poll is null or msg.deleted_at is not null
     or not public.can_read_conversation(msg.conversation_id) then
    raise exception 'not_allowed';
  end if;
  if (msg.poll ->> 'closed')::boolean then
    raise exception 'poll_closed';
  end if;
  if not public.project_is_open((select project_id from conversations
                                 where id = msg.conversation_id)) then
    raise exception 'conversation_closed';
  end if;
  if exists (select 1 from unnest(picks) x
             where x < 0 or x >= jsonb_array_length(msg.poll -> 'options'))
     or (cardinality(picks) > 1 and not (msg.poll ->> 'multiple')::boolean) then
    raise exception 'invalid_vote';
  end if;
  -- Everyone else's votes stay; one's own are replaced.
  for k in select jsonb_object_keys(msg.poll -> 'votes') loop
    votes := votes || jsonb_build_object(k, coalesce(
      (select jsonb_agg(v) from jsonb_array_elements_text(msg.poll -> 'votes' -> k) v
       where v <> me), '[]'::jsonb));
  end loop;
  foreach k in array array(select x::text from unnest(picks) x) loop
    votes := jsonb_set(votes, array[k],
                       coalesce(votes -> k, '[]'::jsonb) || to_jsonb(me));
  end loop;
  update messages
  set poll = jsonb_set(poll, '{votes}',
                       (select coalesce(jsonb_object_agg(key, value), '{}')
                        from jsonb_each(votes) where jsonb_array_length(value) > 0))
  where id = p_message;
end;
$$;

-- Stops a poll taking votes: whoever asked it, or whoever runs the project.
create function public.close_poll(p_message uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  msg messages%rowtype;
  cv  conversations%rowtype;
begin
  select * into msg from messages where id = p_message for update;
  if msg.id is null or msg.poll is null
     or not public.can_read_conversation(msg.conversation_id) then
    raise exception 'not_allowed';
  end if;
  select * into cv from conversations where id = msg.conversation_id;
  if msg.sender_id <> auth.uid()
     and not (cv.kind = 'project' and public.can_manage_project(cv.project_id)) then
    raise exception 'not_allowed';
  end if;
  update messages set poll = jsonb_set(poll, '{closed}', 'true') where id = p_message;
end;
$$;

-- ---------------------------------------------------------------------------
-- Pinned messages
-- ---------------------------------------------------------------------------

create function public.can_pin(cv conversations)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select public.can_read_conversation(cv.id)
     and (cv.kind = 'direct' or public.can_manage_project(cv.project_id));
$$;

-- Pins a message on top of its chat (in place of the one before), or with
-- p_pin false takes it down.
create function public.pin_message(p_message uuid, p_pin boolean default true)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  msg messages%rowtype;
  cv  conversations%rowtype;
begin
  select * into msg from messages where id = p_message;
  if msg.id is null then
    raise exception 'not_allowed';
  end if;
  select * into cv from conversations where id = msg.conversation_id for update;
  if not public.can_pin(cv) or (p_pin and msg.deleted_at is not null) then
    raise exception 'not_allowed';
  end if;
  if not public.project_is_open(cv.project_id) then
    raise exception 'conversation_closed';
  end if;
  if p_pin then
    update conversations
    set pinned_message_id = msg.id, pinned_by = auth.uid(), pinned_at = now()
    where id = cv.id;
  elsif cv.pinned_message_id = msg.id then
    update conversations
    set pinned_message_id = null, pinned_by = null, pinned_at = null
    where id = cv.id;
  end if;
  -- Touches the message so the chat hears of it.
  update messages set reactions = reactions where id = msg.id;
end;
$$;

-- A chat's pinned message, and whether one may change it.
create function public.conversation_pin(p_conversation uuid)
returns table (message_id uuid, sender_name text, body text, file_name text,
               pinned_by_name text, can_pin boolean)
language sql stable security definer set search_path = public, pg_temp as $$
  select m.id, s.full_name, m.body, f.name, pb.full_name, public.can_pin(cv)
  from conversations cv
  left join messages m on m.id = cv.pinned_message_id and m.deleted_at is null
  left join profiles s on s.id = m.sender_id
  left join files f on f.id = m.file_id
  left join profiles pb on pb.id = cv.pinned_by
  where cv.id = p_conversation and public.can_read_conversation(cv.id);
$$;

revoke execute on function
  public.create_poll(uuid, text, text[], boolean, uuid),
  public.vote_poll(uuid, integer[]),
  public.close_poll(uuid),
  public.can_pin(conversations),
  public.pin_message(uuid, boolean),
  public.conversation_pin(uuid)
from public, anon, authenticated;
grant execute on function
  public.create_poll(uuid, text, text[], boolean, uuid),
  public.vote_poll(uuid, integer[]),
  public.close_poll(uuid),
  public.pin_message(uuid, boolean),
  public.conversation_pin(uuid)
to authenticated;
