-- Wasla: chat stage 3.
--
-- * A file added from a project's Files tab is also sent in the project's
--   chat, by the person who added it, and marked as coming from the Files
--   tab (files.from_files). The files list says where each file came from
--   and which message it was sent in, to open the chat at it.
-- * Workspaces choose whether people can share messages and files to other
--   apps (workspaces.allow_sharing, on unless an admin turns it off).
-- * The days a chat has messages on, for its jump-to-date calendar.
-- * Reply chains: a message carries how many replies it gathered (replies to
--   replies included) and who wrote the latest ones; reply_chain lists them.

alter table public.files add column from_files boolean not null default false;
alter table public.workspaces add column allow_sharing boolean not null default true;

grant update (allow_sharing) on public.workspaces to authenticated;

create index messages_reply_idx on public.messages (reply_to) where reply_to is not null;
create index messages_file_idx  on public.messages (file_id)  where file_id is not null;

-- Files added from the Files tab before this were never sent in a chat.
update public.files set from_files = true
where conversation_id is null and task_id is null and project_id is not null;

-- ---------------------------------------------------------------------------
-- Files
-- ---------------------------------------------------------------------------

-- Stores the file and sends it in the project's chat.
create or replace function public.add_project_file(
  p_project uuid, p_path text, p_name text, p_mime text, p_size bigint
) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me   uuid := auth.uid();
  pr   projects%rowtype;
  cv   uuid;
  f    uuid;
  sent timestamptz;
begin
  select * into pr from projects where id = p_project;
  if pr.id is null or not public.can_see_project(pr.id) then
    raise exception 'not_allowed';
  end if;
  if pr.status <> 'active' then
    raise exception 'conversation_closed';
  end if;
  select id into cv from conversations where project_id = pr.id;

  f := public.store_file(pr.workspace_id, pr.id, cv, p_path, p_name, p_mime, p_size);
  update files set from_files = true where id = f;

  insert into messages (conversation_id, workspace_id, sender_id, project_id, file_id)
  values (cv, pr.workspace_id, me, pr.id, f)
  returning created_at into sent;
  update conversations set last_message_at = greatest(last_message_at, sent) where id = cv;
  insert into conversation_reads (conversation_id, user_id, last_read_at)
  values (cv, me, sent)
  on conflict (conversation_id, user_id)
  do update set last_read_at = greatest(conversation_reads.last_read_at, excluded.last_read_at);

  return f;
end;
$$;

-- Files added from the Files tab (and task attachments) can be removed
-- there; one sent from the Files tab takes its chat message with it. Other
-- chat files go with their message.
create or replace function public.delete_file(p_file uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  fl files%rowtype;
begin
  select * into fl from files where id = p_file;
  if fl.id is null or not (fl.conversation_id is null or fl.from_files)
     or not public.can_see_file(fl.id)
     or not (fl.uploaded_by = auth.uid() or public.can_manage_project(fl.project_id)) then
    raise exception 'not_allowed';
  end if;
  if not public.project_is_open(fl.project_id) then
    raise exception 'conversation_closed';
  end if;
  update files set deleted_at = clock_timestamp() where id = fl.id;
  update messages set deleted_at = clock_timestamp(), body = null
  where file_id = fl.id and deleted_at is null;
end;
$$;

drop function public.project_files(uuid);

-- Everything shared in a project that one can see, with where it came from:
-- 'project' (its chat), 'direct' (a private chat tagged with it; other_id
-- and other_name are the other person), 'files' (the Files tab) or 'task'. message_id is
-- the chat message it was sent in, if any.
create function public.project_files(p_project uuid)
returns table (
  id uuid, name text, mime text, size_bytes bigint, storage_path text,
  pinned boolean, uploaded_by uuid, uploader_name text, created_at timestamptz,
  conversation_id uuid, private_chat boolean,
  source text, other_id uuid, other_name text, message_id uuid
)
language sql stable security definer set search_path = public, pg_temp as $$
  select f.id, f.name, f.mime, f.size_bytes, f.storage_path,
         f.pinned, f.uploaded_by, p.full_name, f.created_at,
         f.conversation_id, coalesce(cv.kind = 'direct', false),
         case when cv.kind = 'direct' then 'direct'
              when f.task_id is not null then 'task'
              when f.from_files or f.conversation_id is null then 'files'
              else 'project' end,
         o.id, o.full_name,
         (select m.id from messages m
          where m.file_id = f.id and m.deleted_at is null limit 1)
  from files f
  join profiles p on p.id = f.uploaded_by
  left join conversations cv on cv.id = f.conversation_id
  left join profiles o on cv.kind = 'direct'
    and o.id = case when cv.user_a = auth.uid() then cv.user_b else cv.user_a end
  where f.project_id = p_project and public.can_see_file(f.id)
  order by f.pinned desc, f.created_at desc
  limit 500;
$$;

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------

-- The rows conversation_messages and reply_chain return, for the given
-- messages. Not callable directly: callers check who can read them.
create function public.message_rows(p_ids uuid[])
returns table (
  id uuid, sender_id uuid, sender_name text, body text, project_id uuid,
  created_at timestamptz, deleted boolean,
  reply_to uuid, reply_sender_name text, reply_body text, reply_file_name text,
  file_id uuid, file_name text, file_mime text, file_size bigint, file_path text,
  mentions uuid[], reactions jsonb,
  file_from_files boolean, reply_count integer, repliers uuid[]
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
         coalesce(ch.n, 0), coalesce(ch.people, '{}')
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
  mentions uuid[], reactions jsonb,
  file_from_files boolean, reply_count integer, repliers uuid[]
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
  file_from_files boolean, reply_count integer, repliers uuid[]
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

-- The days (in the reader's time zone, p_utc_offset minutes ahead of UTC)
-- a chat has messages on, newest first.
create function public.conversation_days(
  p_conversation uuid,
  p_project      uuid    default null,
  p_utc_offset   integer default 0
) returns setof date
language sql stable security definer set search_path = public, pg_temp as $$
  select distinct (m.created_at at time zone 'UTC'
                   + make_interval(mins => greatest(least(coalesce(p_utc_offset, 0), 840), -840)))::date d
  from messages m
  where m.conversation_id = p_conversation
    and public.can_read_conversation(p_conversation)
    and m.deleted_at is null
    and (p_project is null or m.project_id = p_project)
  order by d desc
  limit 5000;
$$;

-- ---------------------------------------------------------------------------
-- Function privileges
-- ---------------------------------------------------------------------------

revoke execute on function public.message_rows(uuid[]) from public, anon, authenticated;

revoke execute on function
  public.project_files(uuid),
  public.conversation_messages(uuid, timestamptz, timestamptz, uuid, integer),
  public.reply_chain(uuid),
  public.conversation_days(uuid, uuid, integer)
from public, anon, authenticated;

grant execute on function
  public.project_files(uuid),
  public.conversation_messages(uuid, timestamptz, timestamptz, uuid, integer),
  public.reply_chain(uuid),
  public.conversation_days(uuid, uuid, integer)
to authenticated;
