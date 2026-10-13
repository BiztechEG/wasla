-- Search across a workspace: besides messages (search_messages), the files,
-- tasks and announcements the signed-in user can see. Private chats stay
-- private: their files are only found through search_messages, which only
-- reaches one's own chats.

alter table public.tasks
  add column title_norm text generated always as (public.normalize_ar(title)) stored,
  add column description_norm text generated always as (public.normalize_ar(description)) stored;
alter table public.announcements
  add column body_norm text generated always as (public.normalize_ar(body)) stored;

create function public.search_workspace(p_workspace uuid, p_query text)
returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  with q as (
    select public.normalize_ar(trim(p_query)) as term
  ), p as (
    select '%' || replace(replace(replace(term, '\', '\\'), '%', '\%'), '_', '\_') || '%' as pattern
    from q
    where length(trim(term)) >= 2 and public.is_workspace_member(p_workspace)
  )
  select jsonb_build_object(
    -- Project files and task attachments; files sent in a chat show up as
    -- messages instead.
    'files', coalesce((
      select jsonb_agg(to_jsonb(h) order by h.created_at desc) from (
        select f.id, f.name, f.mime, f.size_bytes, f.storage_path, f.created_at,
               f.task_id, pr.id as project_id, pr.name as project_name,
               pr.color as project_color
        from files f cross join p
        join projects pr on pr.id = f.project_id
        where f.workspace_id = p_workspace and f.deleted_at is null
          and f.conversation_id is null
          and f.name_norm like p.pattern escape '\'
          and public.can_see_file(f.id)
        order by f.created_at desc
        limit 30
      ) h), '[]'::jsonb),
    'tasks', coalesce((
      select jsonb_agg(to_jsonb(h) order by h.done, h.updated_at desc) from (
        select tk.id, tk.title, tk.status, tk.due_at, tk.updated_at,
               tk.status = 'done' as done,
               pr.id as project_id, pr.name as project_name, pr.color as project_color
        from tasks tk cross join p
        join projects pr on pr.id = tk.project_id
        where tk.workspace_id = p_workspace and tk.deleted_at is null
          and (tk.title_norm like p.pattern escape '\'
               or tk.description_norm like p.pattern escape '\')
          and public.can_see_task(tk.id)
        order by tk.status = 'done', tk.updated_at desc
        limit 30
      ) h), '[]'::jsonb),
    'announcements', coalesce((
      select jsonb_agg(to_jsonb(h) order by h.created_at desc) from (
        select a.id, a.body, a.created_at, s.full_name as author_name,
               pr.id as project_id, pr.name as project_name, pr.color as project_color
        from announcements a cross join p
        join profiles s on s.id = a.created_by
        left join projects pr on pr.id = a.project_id
        where a.workspace_id = p_workspace and a.deleted_at is null
          and a.body_norm like p.pattern escape '\'
          and public.can_see_announcements(a.workspace_id, a.project_id)
        order by a.created_at desc
        limit 20
      ) h), '[]'::jsonb)
  );
$$;

revoke execute on function public.search_workspace(uuid, text) from public, anon;
grant execute on function public.search_workspace(uuid, text) to authenticated;
