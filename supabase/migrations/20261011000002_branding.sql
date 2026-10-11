-- Wasla's logo, set from the admin dashboard instead of being fixed in the
-- app.
--
-- A platform admin uploads an image to the public "branding" bucket and saves
-- its path here. The app's sign-in screen and the website read it through
-- public_branding(), which callers who are not signed in can reach: it only
-- says where the logo is. Each upload gets a new name, so phones and browsers
-- never show a cached old logo.

create table public.branding (
  id         boolean primary key default true check (id),
  logo_path  text,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users (id) on delete set null
);

insert into public.branding (id) values (true);

alter table public.branding enable row level security;
-- No policies: only the functions below read or change it.

-- ---------------------------------------------------------------------------
-- Storage: public to read, 2 MB per image, only platform admins write.
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit)
values ('branding', 'branding', true, 2097152)
on conflict (id) do nothing;

create function public.is_logo_object(p_name text)
returns boolean
language sql immutable set search_path = public, pg_temp as $$
  select p_name ~ '^logo/[a-f0-9]{32}\.(png|jpg|jpeg|webp)$';
$$;

create policy wasla_branding_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'branding' and public.is_logo_object(name)
              and public.is_platform_admin());
create policy wasla_branding_delete on storage.objects for delete to authenticated
  using (bucket_id = 'branding' and public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- Functions
-- ---------------------------------------------------------------------------

-- Where the logo is, or null for the built-in one.
create function public.public_branding()
returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('logo_path', logo_path) from branding;
$$;

-- Saves the uploaded logo (null puts back the built-in one) and returns the
-- old path so the app can remove that image.
create function public.set_logo(p_path text)
returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_old text;
begin
  perform public.require_platform_admin();
  if p_path is not null and not public.is_logo_object(p_path) then
    raise exception 'invalid_logo';
  end if;
  select logo_path into v_old from branding for update;
  update branding
     set logo_path = p_path, updated_at = now(), updated_by = auth.uid()
   where id;
  return v_old;
end;
$$;

revoke execute on function
  public.public_branding(),
  public.set_logo(text),
  public.is_logo_object(text)
from public;
grant execute on function public.public_branding() to anon, authenticated;
grant execute on function public.set_logo(text) to authenticated;
grant execute on function public.is_logo_object(text) to authenticated;
