-- Minimal stand-in for the parts of Supabase that the migrations rely on,
-- so they can be tested on a plain PostgreSQL server. Never run on Supabase.

create role anon nologin;
create role authenticated nologin;

create schema auth;

create table auth.users (
  id                 uuid primary key default gen_random_uuid(),
  email              text,
  phone              text,
  raw_user_meta_data jsonb not null default '{}'
);

create function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

grant usage on schema auth to anon, authenticated;
grant usage on schema public to anon, authenticated;
