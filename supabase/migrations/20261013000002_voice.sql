-- Voice messages: phone notifications say 🎤 and the length, not a file name.

create or replace function public.push_message()
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

  perform public.queue_push(people, cv.workspace_id, 'message', title, sender, body,
    jsonb_build_object('type', 'chat', 'conversation', cv.id, 'direct', cv.kind = 'direct'));
  return null;
end;
$$;
