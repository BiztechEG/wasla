-- How far along each project is, for the cards on the projects tab: how many
-- tasks the caller can see, how many are done and how many are late. Done
-- tasks of any age count, so the bar reflects the whole project.

create function public.project_task_counts(p_workspace uuid)
returns table (project_id uuid, total integer, done integer, late integer)
language sql stable security definer set search_path = public, pg_temp as $$
  select p.id,
         count(t.id)::int,
         count(t.id) filter (where t.status = 'done')::int,
         count(t.id) filter (where t.status <> 'done' and t.due_at < now())::int
  from projects p
  join tasks t on t.project_id = p.id and t.deleted_at is null
  where p.workspace_id = p_workspace
    and public.can_see_project(p.id)
    and public.can_see_task(t.id)
  group by p.id;
$$;

revoke execute on function public.project_task_counts(uuid) from public;
grant execute on function public.project_task_counts(uuid) to authenticated;
