-- Presence: what one is up to (in a meeting, busy, on leave), with a note
-- and until when. Everyone in a workspace with one sees it on one's card
-- and in a private chat with one; on leave, the note answers whoever writes.
-- No row, or one past its time, is "available".

create table public.user_status (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  kind    text not null check (kind in ('meeting', 'busy', 'leave')),
  note    text check (length(note) <= 200),
  until   timestamptz,
  set_at  timestamptz not null default now()
);

alter table public.user_status enable row level security;
revoke all on public.user_status from anon, authenticated;

-- Sets one's status, or with a null kind clears it.
create function public.set_my_status(p_kind text, p_note text, p_until timestamptz)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then
    raise exception 'not_allowed';
  end if;
  if p_kind is null then
    delete from user_status where user_id = auth.uid();
    return;
  end if;
  if p_kind not in ('meeting', 'busy', 'leave') then
    raise exception 'invalid_status';
  end if;
  if p_until is not null and p_until <= now() then
    raise exception 'invalid_date';
  end if;
  insert into user_status (user_id, kind, note, until)
  values (auth.uid(), p_kind, nullif(trim(p_note), ''), p_until)
  on conflict (user_id) do update
    set kind = excluded.kind, note = excluded.note, until = excluded.until,
        set_at = now();
end;
$$;

-- The current statuses of a workspace's members, for its members.
create function public.workspace_statuses(p_workspace uuid)
returns table (user_id uuid, kind text, note text, until timestamptz)
language sql stable security definer set search_path = public, pg_temp as $$
  select s.user_id, s.kind, s.note, s.until
  from user_status s
  join workspace_members wm on wm.user_id = s.user_id
   and wm.workspace_id = p_workspace and wm.status = 'active'
  where public.is_workspace_member(p_workspace)
    and (s.until is null or s.until > now());
$$;

revoke execute on function
  public.set_my_status(text, text, timestamptz),
  public.workspace_statuses(uuid)
from public, anon, authenticated;
grant execute on function
  public.set_my_status(text, text, timestamptz),
  public.workspace_statuses(uuid)
to authenticated;
