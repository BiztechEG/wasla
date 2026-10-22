-- Labels ("تصنيفات"): one files messages from any chat under names of one's
-- own, to come back to them by topic. Labels are private: nobody else sees
-- them, not even who sent the message. Each workspace has its own.
--
-- A labelled message shows up only while one can still read it: a deleted
-- message, or one in a chat one has left, drops out of the label.

create table public.message_labels (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles (id) on delete cascade,
  workspace_id uuid not null references public.workspaces (id) on delete cascade,
  name         text not null check (length(name) between 1 and 40),
  created_at   timestamptz not null default now()
);

create unique index message_labels_name_idx
  on public.message_labels (user_id, workspace_id, lower(name));

create table public.labelled_messages (
  label_id   uuid not null references public.message_labels (id) on delete cascade,
  message_id uuid not null references public.messages (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (label_id, message_id)
);

create index labelled_messages_message_idx on public.labelled_messages (message_id);

alter table public.message_labels enable row level security;
alter table public.labelled_messages enable row level security;
revoke all on public.message_labels, public.labelled_messages from anon, authenticated;

-- Whether one may label this message: it is there and one reads its chat.
create function public.label_target(p_message uuid)
returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select m.workspace_id from messages m
  where m.id = p_message and m.deleted_at is null
    and public.can_read_conversation(m.conversation_id);
$$;

-- One's labels in a workspace, the most recently used first, with how many
-- messages each has that one can still read.
create function public.my_labels(p_workspace uuid)
returns table (id uuid, name text, messages integer)
language sql stable security definer set search_path = public, pg_temp as $$
  select l.id, l.name, count(m.id)::int
  from message_labels l
  left join labelled_messages lm on lm.label_id = l.id
  left join messages m on m.id = lm.message_id and m.deleted_at is null
       and public.can_read_conversation(m.conversation_id)
  where l.user_id = auth.uid() and l.workspace_id = p_workspace
  group by l.id
  order by greatest(l.created_at, max(lm.created_at)) desc, l.name;
$$;

-- One's labels on the messages of a chat.
create function public.chat_labels(p_conversation uuid)
returns table (message_id uuid, label_id uuid)
language sql stable security definer set search_path = public, pg_temp as $$
  select lm.message_id, lm.label_id
  from labelled_messages lm
  join message_labels l on l.id = lm.label_id and l.user_id = auth.uid()
  join messages m on m.id = lm.message_id
  where m.conversation_id = p_conversation and m.deleted_at is null
    and public.can_read_conversation(p_conversation);
$$;

-- Files a message under a label: an existing one ([p_label]), or the one
-- named [p_name], made if one has none by that name. Returns the label.
create function public.label_message(p_message uuid, p_label uuid default null,
                                     p_name text default null)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  ws    uuid := public.label_target(p_message);
  label uuid;
  clean text := nullif(regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g'), '');
begin
  if auth.uid() is null or ws is null then
    raise exception 'not_allowed';
  end if;
  if p_label is not null then
    select l.id into label from message_labels l
    where l.id = p_label and l.user_id = auth.uid() and l.workspace_id = ws;
    if label is null then
      raise exception 'not_allowed';
    end if;
  else
    if clean is null or length(clean) > 40 then
      raise exception 'invalid_label';
    end if;
    select l.id into label from message_labels l
    where l.user_id = auth.uid() and l.workspace_id = ws and lower(l.name) = lower(clean);
    if label is null then
      if (select count(*) from message_labels l
          where l.user_id = auth.uid() and l.workspace_id = ws) >= 200 then
        raise exception 'too_many_labels';
      end if;
      insert into message_labels (user_id, workspace_id, name)
      values (auth.uid(), ws, clean)
      on conflict (user_id, workspace_id, lower(name)) do nothing
      returning id into label;
      if label is null then
        -- Made at the same moment from another device.
        select l.id into label from message_labels l
        where l.user_id = auth.uid() and l.workspace_id = ws and lower(l.name) = lower(clean);
      end if;
    end if;
  end if;
  insert into labelled_messages (label_id, message_id) values (label, p_message)
  on conflict do nothing;
  return label;
end;
$$;

create function public.unlabel_message(p_message uuid, p_label uuid)
returns void
language sql security definer set search_path = public, pg_temp as $$
  delete from labelled_messages lm
  using message_labels l
  where lm.label_id = l.id and l.id = p_label and l.user_id = auth.uid()
    and lm.message_id = p_message;
$$;

create function public.rename_label(p_label uuid, p_name text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  clean text := nullif(regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g'), '');
begin
  if clean is null or length(clean) > 40 then
    raise exception 'invalid_label';
  end if;
  update message_labels set name = clean
  where id = p_label and user_id = auth.uid();
  if not found then
    raise exception 'not_allowed';
  end if;
exception when unique_violation then
  raise exception 'label_exists';
end;
$$;

-- Removes the label; the messages stay as they are.
create function public.delete_label(p_label uuid)
returns void
language sql security definer set search_path = public, pg_temp as $$
  delete from message_labels where id = p_label and user_id = auth.uid();
$$;

-- The messages under a label, the newest first; with [p_conversation], only
-- that chat's. Rows are shaped like search_messages' to open the same way.
create function public.labelled(p_label uuid, p_conversation uuid default null)
returns table (
  message_id uuid, conversation_id uuid, created_at timestamptz,
  sender_name text, body text, file_name text,
  kind public.conversation_kind, project_id uuid, project_name text, project_color text,
  other_id uuid, other_name text
)
language sql stable security definer set search_path = public, pg_temp as $$
  select m.id, m.conversation_id, m.created_at, s.full_name, m.body, f.name,
         cv.kind, pr.id, pr.name, pr.color, o.id, o.full_name
  from labelled_messages lm
  join message_labels l on l.id = lm.label_id and l.user_id = auth.uid()
  join messages m on m.id = lm.message_id
  join conversations cv on cv.id = m.conversation_id
  join profiles s on s.id = m.sender_id
  left join files f on f.id = m.file_id
  left join projects pr on pr.id = cv.project_id
  left join profiles o on cv.kind = 'direct'
       and o.id = case when cv.user_a = auth.uid() then cv.user_b else cv.user_a end
  where lm.label_id = p_label
    and (p_conversation is null or m.conversation_id = p_conversation)
    and m.deleted_at is null
    and public.can_read_conversation(m.conversation_id)
  order by m.created_at desc
  limit 500;
$$;

revoke execute on function
  public.label_target(uuid),
  public.my_labels(uuid),
  public.chat_labels(uuid),
  public.label_message(uuid, uuid, text),
  public.unlabel_message(uuid, uuid),
  public.rename_label(uuid, text),
  public.delete_label(uuid),
  public.labelled(uuid, uuid)
from public, anon, authenticated;
grant execute on function
  public.my_labels(uuid),
  public.chat_labels(uuid),
  public.label_message(uuid, uuid, text),
  public.unlabel_message(uuid, uuid),
  public.rename_label(uuid, text),
  public.delete_label(uuid),
  public.labelled(uuid, uuid)
to authenticated;
