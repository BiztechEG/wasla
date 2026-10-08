-- Wasla: phase 2. Chats, files and announcements.
--
-- * Every project has one group chat; any two people in a workspace can talk
--   privately. Private chats are readable by their two people only: no
--   policy or function lets an owner or admin read them.
-- * A private message can be tagged with a project both people work on, so
--   chats can be filtered by person and project together.
-- * Files live in the private Storage bucket "files" under
--   <workspace>/<uploader>/<name>. A file is readable by whoever can read
--   the chat it was sent in, or the project it was added to.
-- * Announcements go to one project, or to the whole workspace, and record
--   who has read them.
-- * Reading goes through functions so messages and files keep their
--   sender's name after that person leaves the workspace. The messages and
--   read-state tables are also readable directly, for live updates.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create type public.conversation_kind as enum ('project', 'direct');

create table public.conversations (
  id              uuid primary key default gen_random_uuid(),
  workspace_id    uuid not null references public.workspaces (id) on delete cascade,
  kind            public.conversation_kind not null,
  project_id      uuid unique references public.projects (id) on delete cascade,
  user_a          uuid references public.profiles (id),
  user_b          uuid references public.profiles (id),
  created_at      timestamptz not null default now(),
  last_message_at timestamptz,
  check ((kind = 'project' and project_id is not null and user_a is null and user_b is null)
      or (kind = 'direct' and project_id is null
          and user_a is not null and user_b is not null and user_a < user_b)),
  unique (workspace_id, user_a, user_b)
);

create table public.files (
  id              uuid primary key default gen_random_uuid(),
  workspace_id    uuid not null references public.workspaces (id) on delete cascade,
  project_id      uuid references public.projects (id) on delete cascade,
  conversation_id uuid references public.conversations (id) on delete cascade,
  storage_path    text not null unique,
  name            text not null check (length(trim(name)) > 0 and length(name) <= 200),
  mime            text not null check (length(mime) <= 100),
  size_bytes      bigint not null check (size_bytes between 0 and 52428800),
  pinned          boolean not null default false,
  uploaded_by     uuid not null references public.profiles (id),
  created_at      timestamptz not null default clock_timestamp(),
  deleted_at      timestamptz,
  check (conversation_id is not null or project_id is not null)
);

create index files_project_idx   on public.files (project_id, created_at desc);
create index files_workspace_idx on public.files (workspace_id);

create table public.messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  workspace_id    uuid not null references public.workspaces (id) on delete cascade,
  sender_id       uuid not null references public.profiles (id),
  body            text check (length(body) <= 4000),
  project_id      uuid references public.projects (id) on delete set null,
  file_id         uuid references public.files (id),
  reply_to        uuid references public.messages (id) on delete set null,
  created_at      timestamptz not null default clock_timestamp(),
  deleted_at      timestamptz
);

create index messages_conversation_idx on public.messages (conversation_id, created_at desc);
create index messages_sender_idx       on public.messages (sender_id, created_at desc);

create table public.conversation_reads (
  conversation_id uuid not null references public.conversations (id) on delete cascade,
  user_id         uuid not null references public.profiles (id) on delete cascade,
  last_read_at    timestamptz not null,
  primary key (conversation_id, user_id)
);

-- project_id null = for the whole workspace.
create table public.announcements (
  id           uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  project_id   uuid references public.projects (id) on delete cascade,
  body         text not null check (length(trim(body)) > 0 and length(body) <= 2000),
  pinned       boolean not null default false,
  created_by   uuid not null references public.profiles (id),
  created_at   timestamptz not null default clock_timestamp(),
  deleted_at   timestamptz
);

create index announcements_scope_idx on public.announcements (workspace_id, project_id, created_at desc);

create table public.announcement_reads (
  announcement_id uuid not null references public.announcements (id) on delete cascade,
  user_id         uuid not null references public.profiles (id) on delete cascade,
  read_at         timestamptz not null default now(),
  primary key (announcement_id, user_id)
);

-- ---------------------------------------------------------------------------
-- Permission helpers
-- ---------------------------------------------------------------------------

-- Private chats: their two people. Project chats: whoever sees the project.
create function public.can_read_conversation(c uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from conversations cv
    where cv.id = c
      and public.is_workspace_member(cv.workspace_id)
      and case cv.kind
            when 'direct'  then auth.uid() in (cv.user_a, cv.user_b)
            when 'project' then public.can_see_project(cv.project_id)
          end
  );
$$;

-- Whether user u sees project p (for tagging a private message with it).
create function public.user_sees_project(u uuid, p uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from projects pr
    join workspace_members wm
      on wm.workspace_id = pr.workspace_id and wm.user_id = u and wm.status = 'active'
    where pr.id = p
      and (wm.role in ('owner', 'admin')
           or exists (select 1 from project_members pm
                      where pm.project_id = p and pm.user_id = u))
  );
$$;

create function public.can_see_file(f uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from files fl
    where fl.id = f and fl.deleted_at is null
      and case when fl.conversation_id is not null
               then public.can_read_conversation(fl.conversation_id)
               else public.can_see_project(fl.project_id)
          end
  );
$$;

-- Uploads go to <workspace>/<own user id>/<name> in a workspace one is in.
create function public.can_upload_object(p_name text)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when p_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[A-Za-z0-9._-]{1,100}$'
    then split_part(p_name, '/', 2) = auth.uid()::text
         and public.is_workspace_member(split_part(p_name, '/', 1)::uuid)
    else false
  end;
$$;

create function public.can_read_object(p_name text)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from files fl
                 where fl.storage_path = p_name and public.can_see_file(fl.id))
      or public.can_upload_object(p_name);
$$;

create function public.can_manage_project(p uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from projects pr where pr.id = p
                 and (public.is_workspace_admin(pr.workspace_id) or public.is_project_lead(p)));
$$;

-- Lower-cases and folds Arabic letter variants and diacritics for search.
create function public.normalize_ar(t text)
returns text
language sql immutable set search_path = public, pg_temp as $$
  select translate(lower(regexp_replace(coalesce(t, ''), '[ً-ْـ]', '', 'g')),
                   'أإآٱىة', 'اااايه');
$$;

-- ---------------------------------------------------------------------------
-- Every project gets its group chat.
-- ---------------------------------------------------------------------------

create function public.add_project_conversation()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into conversations (workspace_id, kind, project_id)
  values (new.workspace_id, 'project', new.id)
  on conflict (project_id) do nothing;
  return new;
end;
$$;

create trigger projects_add_conversation
  after insert on public.projects
  for each row execute function public.add_project_conversation();

insert into public.conversations (workspace_id, kind, project_id)
select workspace_id, 'project', id from public.projects
on conflict (project_id) do nothing;

-- ---------------------------------------------------------------------------
-- Chats
-- ---------------------------------------------------------------------------

-- The private chat between the signed-in user and p_other, created if new.
create function public.open_direct(p_workspace uuid, p_other uuid)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  me uuid := auth.uid();
  a  uuid := least(me, p_other);
  b  uuid := greatest(me, p_other);
  c  uuid;
begin
  if p_other is null or p_other = me
     or not public.is_workspace_member(p_workspace)
     or not exists (select 1 from workspace_members
                    where workspace_id = p_workspace and user_id = p_other and status = 'active')
  then
    raise exception 'not_allowed';
  end if;

  insert into conversations (workspace_id, kind, user_a, user_b)
  values (p_workspace, 'direct', a, b)
  on conflict (workspace_id, user_a, user_b) do nothing
  returning id into c;

  if c is null then
    select id into c from conversations
    where workspace_id = p_workspace and user_a = a and user_b = b;
  end if;
  return c;
end;
$$;

-- A project's group chat, for anyone who sees the project.
create function public.project_conversation(p_project uuid)
returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select id from conversations
  where project_id = p_project and public.can_see_project(p_project);
$$;

-- Records an uploaded file. Used by send_message and add_project_file.
create function public.store_file(
  p_workspace uuid, p_project uuid, p_conversation uuid,
  p_path text, p_name text, p_mime text, p_size bigint
) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  quota bigint;
  used  bigint;
  f     uuid;
begin
  if split_part(p_path, '/', 1) <> p_workspace::text or not public.can_upload_object(p_path) then
    raise exception 'invalid_file';
  end if;
  if p_size is null or p_size < 0 or p_size > 52428800 then
    raise exception 'file_too_large';
  end if;

  select p.storage_gb::bigint * 1073741824 into quota
  from workspaces w join plans p on p.id = w.plan_id
  where w.id = p_workspace;
  if quota is not null then
    select coalesce(sum(size_bytes), 0) into used
    from files where workspace_id = p_workspace and deleted_at is null;
    if used + p_size > quota then
      raise exception 'storage_full';
    end if;
  end if;

  insert into files (workspace_id, project_id, conversation_id, storage_path,
                     name, mime, size_bytes, uploaded_by)
  values (p_workspace, p_project, p_conversation, p_path,
          coalesce(nullif(trim(p_name), ''), 'file'),
          coalesce(nullif(trim(p_mime), ''), 'application/octet-stream'),
          p_size, auth.uid())
  returning id into f;
  return f;
end;
$$;

create function public.send_message(
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

  update conversations set last_message_at = sent where id = cv.id;

  -- Sending a message means having read the chat up to it.
  insert into conversation_reads (conversation_id, user_id, last_read_at)
  values (cv.id, me, sent)
  on conflict (conversation_id, user_id)
  do update set last_read_at = greatest(conversation_reads.last_read_at, excluded.last_read_at);

  return m;
end;
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
  file_id uuid, file_name text, file_mime text, file_size bigint, file_path text
)
language sql stable security definer set search_path = public, pg_temp as $$
  select m.id, m.sender_id, s.full_name, m.body, m.project_id,
         m.created_at, m.deleted_at is not null,
         m.reply_to, rs.full_name,
         case when r.deleted_at is null then r.body end,
         case when r.deleted_at is null then rf.name end,
         f.id, f.name, f.mime, f.size_bytes, f.storage_path
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

create function public.mark_read(p_conversation uuid, p_until timestamptz default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.can_read_conversation(p_conversation) then
    raise exception 'not_allowed';
  end if;
  insert into conversation_reads (conversation_id, user_id, last_read_at)
  values (p_conversation, auth.uid(), least(coalesce(p_until, clock_timestamp()), clock_timestamp()))
  on conflict (conversation_id, user_id)
  do update set last_read_at = greatest(conversation_reads.last_read_at, excluded.last_read_at);
end;
$$;

-- Senders delete their own messages; admins and leads tidy project chats.
create function public.delete_message(p_message uuid)
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

  update messages set deleted_at = clock_timestamp(), body = null where id = m.id;
  update files set deleted_at = clock_timestamp() where id = m.file_id;
end;
$$;

-- The chat list: project chats one belongs to and private chats with
-- messages, latest first.
create function public.my_conversations(p_workspace uuid)
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
         o.id, o.full_name, coalesce(wm.status = 'active', false),
         lm.created_at, lm.sender_id, ls.full_name,
         lm.body, lf.name, lm.deleted_at is not null,
         (select count(*)::int from messages x
          where x.conversation_id = cv.id and x.sender_id <> auth.uid() and x.deleted_at is null
            and x.created_at > coalesce(rd.last_read_at, '-infinity')),
         case when cv.kind = 'direct' then
           array(select distinct x.project_id from messages x
                 where x.conversation_id = cv.id and x.project_id is not null
                   and x.deleted_at is null and public.can_see_project(x.project_id))
         else array[cv.project_id] end
  from mine cv
  left join projects pr          on pr.id = cv.project_id
  left join profiles o           on cv.kind = 'direct' and o.id = cv.other
  left join workspace_members wm on wm.workspace_id = cv.workspace_id and wm.user_id = o.id
  left join conversation_reads rd on rd.conversation_id = cv.id and rd.user_id = auth.uid()
  left join lateral (select * from messages x where x.conversation_id = cv.id
                     order by x.created_at desc limit 1) lm on true
  left join profiles ls on ls.id = lm.sender_id
  left join files lf    on lf.id = lm.file_id
  order by coalesce(lm.created_at, cv.created_at) desc;
$$;

-- Messages and file names, with Arabic letter variants treated alike.
create function public.search_messages(p_workspace uuid, p_query text)
returns table (
  message_id uuid, conversation_id uuid, created_at timestamptz,
  sender_name text, body text, file_name text
)
language sql stable security definer set search_path = public, pg_temp as $$
  with q as (
    select '%' || replace(replace(replace(public.normalize_ar(trim(p_query)),
             '\', '\\'), '%', '\%'), '_', '\_') || '%' as pattern
  ), readable as (
    select cv.id from conversations cv
    where cv.workspace_id = p_workspace and public.can_read_conversation(cv.id)
  )
  select m.id, m.conversation_id, m.created_at, s.full_name, m.body, f.name
  from messages m
  join readable r on r.id = m.conversation_id
  join profiles s on s.id = m.sender_id
  left join files f on f.id = m.file_id
  cross join q
  where length(trim(p_query)) >= 2
    and m.deleted_at is null
    and (public.normalize_ar(m.body) like q.pattern escape '\'
         or public.normalize_ar(f.name) like q.pattern escape '\')
  order by m.created_at desc
  limit 50;
$$;

-- ---------------------------------------------------------------------------
-- Files
-- ---------------------------------------------------------------------------

-- Everything shared in a project, wherever it was sent, that one can see.
create function public.project_files(p_project uuid)
returns table (
  id uuid, name text, mime text, size_bytes bigint, storage_path text,
  pinned boolean, uploaded_by uuid, uploader_name text, created_at timestamptz,
  conversation_id uuid, private_chat boolean
)
language sql stable security definer set search_path = public, pg_temp as $$
  select f.id, f.name, f.mime, f.size_bytes, f.storage_path,
         f.pinned, f.uploaded_by, p.full_name, f.created_at,
         f.conversation_id, coalesce(cv.kind = 'direct', false)
  from files f
  join profiles p on p.id = f.uploaded_by
  left join conversations cv on cv.id = f.conversation_id
  where f.project_id = p_project and public.can_see_file(f.id)
  order by f.pinned desc, f.created_at desc
  limit 500;
$$;

create function public.add_project_file(
  p_project uuid, p_path text, p_name text, p_mime text, p_size bigint
) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  pr projects%rowtype;
begin
  select * into pr from projects where id = p_project;
  if pr.id is null or not public.can_see_project(pr.id) then
    raise exception 'not_allowed';
  end if;
  if pr.status <> 'active' then
    raise exception 'conversation_closed';
  end if;
  return public.store_file(pr.workspace_id, pr.id, null, p_path, p_name, p_mime, p_size);
end;
$$;

-- Pinning is for project files everyone in the project sees.
create function public.set_file_pinned(p_file uuid, p_pinned boolean)
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
  update files set pinned = p_pinned where id = fl.id;
end;
$$;

-- Files added to a project directly. Chat files go with their message.
create function public.delete_file(p_file uuid)
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
  update files set deleted_at = clock_timestamp() where id = fl.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Announcements
-- ---------------------------------------------------------------------------

create function public.can_see_announcements(p_workspace uuid, p_project uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when p_project is null then public.is_workspace_member(p_workspace)
    else exists (select 1 from projects where id = p_project and workspace_id = p_workspace)
         and public.can_see_project(p_project)
  end;
$$;

create function public.can_post_announcements(p_workspace uuid, p_project uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when p_project is null then public.is_workspace_admin(p_workspace)
    else exists (select 1 from projects where id = p_project and workspace_id = p_workspace)
         and public.can_manage_project(p_project)
  end;
$$;

-- Who an announcement is for: the project's people, or the workspace's.
create function public.announcement_audience(a uuid)
returns table (user_id uuid)
language sql stable security definer set search_path = public, pg_temp as $$
  select pm.user_id from announcements an
  join project_members pm on pm.project_id = an.project_id
  where an.id = a and an.project_id is not null
  union
  select wm.user_id from announcements an
  join workspace_members wm on wm.workspace_id = an.workspace_id and wm.status = 'active'
  where an.id = a and an.project_id is null;
$$;

create function public.announcements_for(p_workspace uuid, p_project uuid default null)
returns table (
  id uuid, project_id uuid, body text, pinned boolean,
  author_id uuid, author_name text, created_at timestamptz,
  read_by_me boolean, read_count integer, audience integer
)
language sql stable security definer set search_path = public, pg_temp as $$
  select a.id, a.project_id, a.body, a.pinned,
         a.created_by, p.full_name, a.created_at,
         exists (select 1 from announcement_reads r
                 where r.announcement_id = a.id and r.user_id = auth.uid()),
         (select count(*)::int from announcement_reads r
          join public.announcement_audience(a.id) au on au.user_id = r.user_id
          where r.announcement_id = a.id and r.user_id <> a.created_by),
         (select count(*)::int from public.announcement_audience(a.id) au
          where au.user_id <> a.created_by)
  from announcements a
  join profiles p on p.id = a.created_by
  where a.workspace_id = p_workspace
    and a.project_id is not distinct from p_project
    and a.deleted_at is null
    and public.can_see_announcements(p_workspace, p_project)
  order by a.pinned desc, a.created_at desc
  limit 100;
$$;

-- Unread announcements for the chat list: the workspace's, and those of
-- projects one belongs to, from the last 30 days.
create function public.unread_announcements(p_workspace uuid)
returns table (
  id uuid, project_id uuid, project_name text, project_color text,
  body text, author_name text, created_at timestamptz
)
language sql stable security definer set search_path = public, pg_temp as $$
  select a.id, a.project_id, pr.name, pr.color, a.body, p.full_name, a.created_at
  from announcements a
  join profiles p on p.id = a.created_by
  left join projects pr on pr.id = a.project_id
  where a.workspace_id = p_workspace
    and public.is_workspace_member(p_workspace)
    and a.deleted_at is null
    and a.created_by <> auth.uid()
    and a.created_at > now() - interval '30 days'
    and (a.project_id is null
         or (pr.status = 'active'
             and exists (select 1 from project_members pm
                         where pm.project_id = a.project_id and pm.user_id = auth.uid())))
    and not exists (select 1 from announcement_reads r
                    where r.announcement_id = a.id and r.user_id = auth.uid())
  order by a.created_at desc
  limit 20;
$$;

create function public.post_announcement(
  p_workspace uuid, p_project uuid, p_body text, p_pinned boolean default false
) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  a uuid;
begin
  if not public.can_post_announcements(p_workspace, p_project) then
    raise exception 'not_allowed';
  end if;
  if p_project is not null
     and (select status from projects where id = p_project) <> 'active' then
    raise exception 'conversation_closed';
  end if;
  if (select count(*) from announcements
      where created_by = auth.uid() and created_at > now() - interval '1 day') >= 50 then
    raise exception 'too_many_requests';
  end if;

  insert into announcements (workspace_id, project_id, body, pinned, created_by)
  values (p_workspace, p_project, trim(p_body), coalesce(p_pinned, false), auth.uid())
  returning id into a;
  return a;
end;
$$;

create function public.mark_announcements_read(p_ids uuid[])
returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into announcement_reads (announcement_id, user_id)
  select a.id, auth.uid() from announcements a
  where a.id = any (p_ids) and a.deleted_at is null
    and public.can_see_announcements(a.workspace_id, a.project_id)
  on conflict do nothing;
$$;

create function public.set_announcement_pinned(p_id uuid, p_pinned boolean)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  an announcements%rowtype;
begin
  select * into an from announcements where id = p_id and deleted_at is null;
  if an.id is null or not public.can_post_announcements(an.workspace_id, an.project_id) then
    raise exception 'not_allowed';
  end if;
  update announcements set pinned = p_pinned where id = an.id;
end;
$$;

create function public.delete_announcement(p_id uuid)
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
  update announcements set deleted_at = clock_timestamp() where id = an.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Row Level Security. Only messages and read state are readable directly,
-- so the app can follow them live; everything else goes through the
-- functions above.
-- ---------------------------------------------------------------------------

alter table public.conversations      enable row level security;
alter table public.files              enable row level security;
alter table public.messages           enable row level security;
alter table public.conversation_reads enable row level security;
alter table public.announcements      enable row level security;
alter table public.announcement_reads enable row level security;

revoke all on public.conversations, public.files, public.messages,
              public.conversation_reads, public.announcements,
              public.announcement_reads
from anon, authenticated;

grant select on public.messages to authenticated;
create policy messages_read on public.messages for select to authenticated
  using (public.can_read_conversation(conversation_id));

grant select on public.conversation_reads to authenticated;
create policy conversation_reads_read on public.conversation_reads for select to authenticated
  using (public.can_read_conversation(conversation_id));

-- Live updates (Supabase Realtime follows the read policies above).
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.messages, public.conversation_reads;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Storage: a private bucket, 50 MB per file.
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit)
values ('files', 'files', false, 52428800)
on conflict (id) do nothing;

create policy wasla_files_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'files' and public.can_upload_object(name));
create policy wasla_files_read on storage.objects for select to authenticated
  using (bucket_id = 'files' and public.can_read_object(name));

-- ---------------------------------------------------------------------------
-- Function privileges
-- ---------------------------------------------------------------------------

revoke execute on function
  public.can_read_conversation(uuid),
  public.user_sees_project(uuid, uuid),
  public.can_see_file(uuid),
  public.can_upload_object(text),
  public.can_read_object(text),
  public.can_manage_project(uuid),
  public.normalize_ar(text),
  public.add_project_conversation(),
  public.open_direct(uuid, uuid),
  public.project_conversation(uuid),
  public.store_file(uuid, uuid, uuid, text, text, text, bigint),
  public.send_message(uuid, text, uuid, uuid, text, text, text, bigint),
  public.conversation_messages(uuid, timestamptz, timestamptz, uuid, integer),
  public.mark_read(uuid, timestamptz),
  public.delete_message(uuid),
  public.my_conversations(uuid),
  public.search_messages(uuid, text),
  public.project_files(uuid),
  public.add_project_file(uuid, text, text, text, bigint),
  public.set_file_pinned(uuid, boolean),
  public.delete_file(uuid),
  public.can_see_announcements(uuid, uuid),
  public.can_post_announcements(uuid, uuid),
  public.announcement_audience(uuid),
  public.announcements_for(uuid, uuid),
  public.unread_announcements(uuid),
  public.post_announcement(uuid, uuid, text, boolean),
  public.mark_announcements_read(uuid[]),
  public.set_announcement_pinned(uuid, boolean),
  public.delete_announcement(uuid)
from public, anon, authenticated;

-- Policy helpers (row and storage policies run them as the signed-in user)
-- and the actions the app calls.
grant execute on function
  public.can_read_conversation(uuid),
  public.can_upload_object(text),
  public.can_read_object(text),
  public.open_direct(uuid, uuid),
  public.project_conversation(uuid),
  public.send_message(uuid, text, uuid, uuid, text, text, text, bigint),
  public.conversation_messages(uuid, timestamptz, timestamptz, uuid, integer),
  public.mark_read(uuid, timestamptz),
  public.delete_message(uuid),
  public.my_conversations(uuid),
  public.search_messages(uuid, text),
  public.project_files(uuid),
  public.add_project_file(uuid, text, text, text, bigint),
  public.set_file_pinned(uuid, boolean),
  public.delete_file(uuid),
  public.announcements_for(uuid, uuid),
  public.unread_announcements(uuid),
  public.post_announcement(uuid, uuid, text, boolean),
  public.mark_announcements_read(uuid[]),
  public.set_announcement_pinned(uuid, boolean),
  public.delete_announcement(uuid)
to authenticated;
