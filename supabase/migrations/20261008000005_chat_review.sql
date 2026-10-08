-- Wasla: fixes from the phase 2 review.
--
-- * Storage: a file's size is read from the stored object, never taken from
--   the app. Everything uploaded to a workspace counts against its plan,
--   including uploads that were never sent, and each person has a daily
--   upload allowance per workspace. People can remove their own uploads that
--   no message or project file uses (a failed send, a deleted message).
-- * Closed and archived projects are fully read-only.
-- * Someone added to a project starts with its chat read.
-- * Faster read checks for live updates and search, and read receipts carry
--   their workspace so the app only follows its own.

-- ---------------------------------------------------------------------------
-- Search: more letter variants and marks (مسؤول and مسئول match); stored
-- normalized text.
-- ---------------------------------------------------------------------------

create or replace function public.normalize_ar(t text)
returns text
language sql immutable set search_path = public, pg_temp as $$
  select translate(lower(regexp_replace(coalesce(t, ''), '[ً-ٰٟـ]', '', 'g')),
                   'أإآٱىةؤئیک', 'اااايهءءيك');
$$;

alter table public.messages
  add column body_norm text generated always as (public.normalize_ar(body)) stored;
alter table public.files
  add column name_norm text generated always as (public.normalize_ar(name)) stored;

-- The projects a private chat has been tagged with (chat list, filters).
create index messages_tags_idx on public.messages (conversation_id, project_id)
  where project_id is not null and deleted_at is null;

-- ---------------------------------------------------------------------------
-- Read checks that run once per query instead of once per row.
-- ---------------------------------------------------------------------------

-- Every chat the signed-in user can read, in workspaces they are active in.
create function public.my_conversation_ids()
returns setof uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select cv.id from conversations cv
  join workspace_members wm
    on wm.workspace_id = cv.workspace_id and wm.user_id = auth.uid() and wm.status = 'active'
  where (cv.kind = 'direct' and auth.uid() in (cv.user_a, cv.user_b))
     or (cv.kind = 'project' and public.can_see_project(cv.project_id));
$$;

drop policy messages_read on public.messages;
create policy messages_read on public.messages for select to authenticated
  using (conversation_id in (select public.my_conversation_ids()));

-- Read receipts carry their workspace, so live updates can be filtered by it.
alter table public.conversation_reads add column workspace_id uuid
  references public.workspaces (id) on delete cascade;
update public.conversation_reads r set workspace_id = cv.workspace_id
from public.conversations cv where cv.id = r.conversation_id;
alter table public.conversation_reads alter column workspace_id set not null;

create function public.conversation_reads_fill()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  select workspace_id into new.workspace_id from conversations where id = new.conversation_id;
  return new;
end;
$$;

create trigger conversation_reads_fill
  before insert on public.conversation_reads
  for each row execute function public.conversation_reads_fill();

drop policy conversation_reads_read on public.conversation_reads;
create policy conversation_reads_read on public.conversation_reads for select to authenticated
  using (conversation_id in (select public.my_conversation_ids()));

-- Someone added to a project starts with its chat read, not its whole
-- history unread.
create function public.project_member_reads()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into conversation_reads (conversation_id, user_id, last_read_at)
  select cv.id, new.user_id, clock_timestamp()
  from conversations cv where cv.project_id = new.project_id
  on conflict (conversation_id, user_id)
  do update set last_read_at = greatest(conversation_reads.last_read_at, excluded.last_read_at);
  return new;
end;
$$;

create trigger project_members_reads
  after insert on public.project_members
  for each row execute function public.project_member_reads();

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

-- A private bucket, even if one with this name was made by hand before.
insert into storage.buckets (id, name, public, file_size_limit)
values ('files', 'files', false, 52428800)
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit;

-- Bytes stored under a folder of the bucket, sent or not.
create function public.stored_bytes(p_prefix text, p_since timestamptz default null)
returns bigint
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum((o.metadata ->> 'size')::bigint), 0)
  from storage.objects o
  where o.bucket_id = 'files' and o.name like p_prefix || '%'
    and (p_since is null or o.created_at > p_since);
$$;

-- An upload is allowed into one's own folder of a workspace one is in, while
-- the workspace has room on its plan and the person is within today's
-- allowance there (2 GB and 500 files).
create function public.can_store_object(p_name text)
returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  ws     text := split_part(p_name, '/', 1);
  folder text := ws || '/' || split_part(p_name, '/', 2) || '/';
  quota  bigint;
begin
  if not public.can_upload_object(p_name) then
    return false;
  end if;
  if public.stored_bytes(folder, now() - interval '1 day') >= 2147483648
     or (select count(*) from storage.objects o
         where o.bucket_id = 'files' and o.name like folder || '%'
           and o.created_at > now() - interval '1 day') >= 500 then
    return false;
  end if;
  select p.storage_gb::bigint * 1073741824 into quota
  from workspaces w join plans p on p.id = w.plan_id
  where w.id = ws::uuid;
  return quota is null or public.stored_bytes(ws || '/') < quota;
end;
$$;

-- One's own uploads that nothing uses any more can be removed.
create function public.can_remove_object(p_name text)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select split_part(p_name, '/', 2) = auth.uid()::text
     and not exists (select 1 from files where storage_path = p_name and deleted_at is null);
$$;

drop policy wasla_files_upload on storage.objects;
create policy wasla_files_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'files' and public.can_store_object(name));
create policy wasla_files_remove on storage.objects for delete to authenticated
  using (bucket_id = 'files' and public.can_remove_object(name));

-- Records an uploaded file. The size comes from the stored object.
create or replace function public.store_file(
  p_workspace uuid, p_project uuid, p_conversation uuid,
  p_path text, p_name text, p_mime text, p_size bigint
) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me    uuid := auth.uid();
  found boolean;
  size  bigint;
  quota bigint;
  f     uuid;
begin
  if split_part(p_path, '/', 1) <> p_workspace::text or not public.can_upload_object(p_path) then
    raise exception 'invalid_file';
  end if;
  select true, (o.metadata ->> 'size')::bigint into found, size
  from storage.objects o where o.bucket_id = 'files' and o.name = p_path;
  if found is null then
    raise exception 'invalid_file';
  end if;
  size := coalesce(size, p_size);
  if size is null or size < 0 or size > 52428800 then
    raise exception 'file_too_large';
  end if;

  perform pg_advisory_xact_lock(hashtext('wasla_files:' || me::text));
  if (select count(*) from files
      where uploaded_by = me and created_at > now() - interval '1 minute') >= 30 then
    raise exception 'too_many_requests';
  end if;

  -- One file at a time per workspace, so two uploads cannot both squeeze in.
  perform 1 from workspaces where id = p_workspace for update;
  select p.storage_gb::bigint * 1073741824 into quota
  from workspaces w join plans p on p.id = w.plan_id
  where w.id = p_workspace;
  if quota is not null and public.stored_bytes(p_workspace::text || '/') > quota then
    raise exception 'storage_full';
  end if;

  insert into files (workspace_id, project_id, conversation_id, storage_path,
                     name, mime, size_bytes, uploaded_by)
  values (p_workspace, p_project, p_conversation, p_path,
          coalesce(nullif(trim(p_name), ''), 'file'),
          coalesce(nullif(trim(p_mime), ''), 'application/octet-stream'),
          size, me)
  returning id into f;
  return f;
end;
$$;

-- ---------------------------------------------------------------------------
-- Chats
-- ---------------------------------------------------------------------------

create or replace function public.send_message(
  p_conversation uuid,
  p_body         text   default null,
  p_reply_to     uuid   default null,
  p_project      uuid   default null,
  p_file_path    text   default null,
  p_file_name    text   default null,
  p_file_mime    text   default null,
  p_file_size    bigint default null
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

  if p_file_path is not null then
    f := public.store_file(cv.workspace_id, tag, cv.id, p_file_path,
                           p_file_name, p_file_mime, p_file_size);
  end if;

  insert into messages (conversation_id, workspace_id, sender_id, body, project_id, file_id, reply_to)
  values (cv.id, cv.workspace_id, me, p_body, tag, f, p_reply_to)
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

-- A closed or archived project's chat, files and announcements stay as they
-- are until it is reopened.
create function public.project_is_open(p uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select p is null or exists (select 1 from projects where id = p and status = 'active');
$$;

create or replace function public.delete_message(p_message uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  m  messages%rowtype;
  cv conversations%rowtype;
begin
  select * into m from messages where id = p_message for update;
  if m.id is null or m.deleted_at is not null
     or not public.can_read_conversation(m.conversation_id) then
    raise exception 'not_allowed';
  end if;
  select * into cv from conversations where id = m.conversation_id;
  if m.sender_id <> auth.uid()
     and not (cv.kind = 'project' and public.can_manage_project(cv.project_id)) then
    raise exception 'not_allowed';
  end if;
  if not public.project_is_open(cv.project_id) then
    raise exception 'conversation_closed';
  end if;

  update messages set deleted_at = clock_timestamp(), body = null where id = m.id;
  update files set deleted_at = clock_timestamp() where id = m.file_id;
end;
$$;

-- The chat list: project chats one belongs to and private chats with
-- messages, latest first.
create or replace function public.my_conversations(p_workspace uuid)
returns table (
  id uuid, kind public.conversation_kind,
  project_id uuid, project_name text, project_color text,
  other_id uuid, other_name text, other_active boolean,
  last_at timestamptz, last_sender_id uuid, last_sender_name text,
  last_body text, last_file_name text, last_deleted boolean,
  unread integer, tag_project_ids uuid[]
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
         else array[cv.project_id] end
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

-- Messages and file names, with Arabic letter variants treated alike. Each
-- hit says which chat it is in, so the app can open chats that are not in
-- its list (a closed project, or a project an admin is not part of).
drop function public.search_messages(uuid, text);
create function public.search_messages(p_workspace uuid, p_query text)
returns table (
  message_id uuid, conversation_id uuid, created_at timestamptz,
  sender_name text, body text, file_name text,
  kind public.conversation_kind, project_id uuid, project_name text, project_color text,
  other_id uuid, other_name text
)
language sql stable security definer set search_path = public, pg_temp as $$
  with q as (
    select public.normalize_ar(trim(p_query)) as term
  ), p as (
    select '%' || replace(replace(replace(term, '\', '\\'), '%', '\%'), '_', '\_') || '%' as pattern
    from q where length(trim(term)) >= 2
  )
  select m.id, m.conversation_id, m.created_at, s.full_name, m.body, f.name,
         cv.kind, pr.id, pr.name, pr.color, o.id, o.full_name
  from messages m
  cross join p
  join conversations cv on cv.id = m.conversation_id
  join profiles s on s.id = m.sender_id
  left join files f on f.id = m.file_id
  left join projects pr on pr.id = cv.project_id
  left join profiles o on cv.kind = 'direct'
       and o.id = case when cv.user_a = auth.uid() then cv.user_b else cv.user_a end
  where m.workspace_id = p_workspace
    and m.conversation_id in (select public.my_conversation_ids())
    and m.deleted_at is null
    and (m.body_norm like p.pattern escape '\' or f.name_norm like p.pattern escape '\')
  order by m.created_at desc
  limit 50;
$$;

-- Projects a private message can be tagged with: active ones both people see.
create function public.shared_projects(p_conversation uuid)
returns setof uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select pr.id from conversations cv
  join projects pr on pr.workspace_id = cv.workspace_id and pr.status = 'active'
  where cv.id = p_conversation and cv.kind = 'direct'
    and public.can_read_conversation(cv.id)
    and public.user_sees_project(cv.user_a, pr.id)
    and public.user_sees_project(cv.user_b, pr.id);
$$;

-- ---------------------------------------------------------------------------
-- Files and announcements in closed projects stay as they are.
-- ---------------------------------------------------------------------------

create or replace function public.set_file_pinned(p_file uuid, p_pinned boolean)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  fl files%rowtype;
begin
  select * into fl from files where id = p_file;
  if fl.id is null or fl.project_id is null or not public.can_see_file(fl.id)
     or not public.can_manage_project(fl.project_id)
     or exists (select 1 from conversations where id = fl.conversation_id and kind = 'direct') then
    raise exception 'not_allowed';
  end if;
  if not public.project_is_open(fl.project_id) then
    raise exception 'conversation_closed';
  end if;
  update files set pinned = p_pinned where id = fl.id;
end;
$$;

create or replace function public.delete_file(p_file uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  fl files%rowtype;
begin
  select * into fl from files where id = p_file;
  if fl.id is null or fl.conversation_id is not null or not public.can_see_file(fl.id)
     or not (fl.uploaded_by = auth.uid() or public.can_manage_project(fl.project_id)) then
    raise exception 'not_allowed';
  end if;
  if not public.project_is_open(fl.project_id) then
    raise exception 'conversation_closed';
  end if;
  update files set deleted_at = clock_timestamp() where id = fl.id;
end;
$$;

create or replace function public.set_announcement_pinned(p_id uuid, p_pinned boolean)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  an announcements%rowtype;
begin
  select * into an from announcements where id = p_id and deleted_at is null;
  if an.id is null or not public.can_post_announcements(an.workspace_id, an.project_id) then
    raise exception 'not_allowed';
  end if;
  if not public.project_is_open(an.project_id) then
    raise exception 'conversation_closed';
  end if;
  update announcements set pinned = p_pinned where id = an.id;
end;
$$;

create or replace function public.delete_announcement(p_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  an announcements%rowtype;
begin
  select * into an from announcements where id = p_id and deleted_at is null;
  if an.id is null
     or not public.can_see_announcements(an.workspace_id, an.project_id)
     or not (an.created_by = auth.uid()
             or public.can_post_announcements(an.workspace_id, an.project_id)) then
    raise exception 'not_allowed';
  end if;
  if not public.project_is_open(an.project_id) then
    raise exception 'conversation_closed';
  end if;
  update announcements set deleted_at = clock_timestamp() where id = an.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Function privileges
-- ---------------------------------------------------------------------------

revoke execute on function
  public.my_conversation_ids(),
  public.conversation_reads_fill(),
  public.project_member_reads(),
  public.stored_bytes(text, timestamptz),
  public.can_store_object(text),
  public.can_remove_object(text),
  public.project_is_open(uuid),
  public.search_messages(uuid, text),
  public.shared_projects(uuid)
from public, anon, authenticated;

-- Policy helpers: row and storage policies run them as the signed-in user.
grant execute on function
  public.my_conversation_ids(),
  public.can_store_object(text),
  public.can_remove_object(text)
to authenticated;

-- Actions the app calls.
grant execute on function
  public.search_messages(uuid, text),
  public.shared_projects(uuid)
to authenticated;
