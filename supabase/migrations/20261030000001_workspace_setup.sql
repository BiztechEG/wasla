-- The first steps of a new workspace, for its owners and admins: a first
-- project, the team invited, attendance set up and a first announcement.
-- The app shows them as a checklist on the home screen until they are done.

create function public.workspace_setup(p_workspace uuid)
returns table (has_project boolean, has_team boolean, attendance_on boolean,
               has_announcement boolean)
language sql stable security definer set search_path = public, pg_temp as $$
  select
    exists (select 1 from projects p where p.workspace_id = p_workspace),
    -- Someone else in it, or on the way: an invitation or the join link.
    exists (select 1 from workspace_members wm
            where wm.workspace_id = p_workspace and wm.user_id <> auth.uid()
              and wm.status = 'active')
      or exists (select 1 from invites i
                 where i.workspace_id = p_workspace and i.status = 'pending'
                   and i.expires_at > now())
      or exists (select 1 from workspace_join_codes c where c.workspace_id = p_workspace),
    coalesce((select s.enabled from attendance_settings s
              where s.workspace_id = p_workspace), false),
    exists (select 1 from announcements a
            where a.workspace_id = p_workspace and a.deleted_at is null)
  where public.is_workspace_admin(p_workspace);
$$;

revoke execute on function public.workspace_setup(uuid) from public, anon, authenticated;
grant execute on function public.workspace_setup(uuid) to authenticated;
