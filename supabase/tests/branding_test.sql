-- The logo platform admins set from the dashboard.

\set ON_ERROR_STOP on

-- Users: Hala (a platform admin) and Omar (everyone else).
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-000000000901', 'hala@example.com', '{"full_name":"Hala"}'),
  ('00000000-0000-0000-0000-000000000902', 'omar@example.com', '{"full_name":"Omar"}');
insert into public.platform_admins (user_id) values
  ('00000000-0000-0000-0000-000000000901');

create function pg_temp.login(n int) returns void language sql as $$
  select set_config('role', 'authenticated', false),
         set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000' || n, false);
$$;

create function pg_temp.anon() returns void language sql as $$
  select set_config('role', 'anon', false),
         set_config('request.jwt.claim.sub', '', false);
$$;

create function pg_temp.check(ok boolean, what text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'FAILED: %', what; end if;
  raise notice 'ok: %', what;
end;
$$;

create function pg_temp.fails(stmt text, err text, what text) returns void language plpgsql as $$
begin
  execute stmt;
  raise exception 'FAILED: % (it worked)', what;
exception when others then
  if sqlerrm like 'FAILED:%' then raise; end if;
  if sqlerrm <> err and sqlstate <> err then
    raise exception 'FAILED: % (got % / %)', what, sqlerrm, sqlstate;
  end if;
  raise notice 'ok: %', what;
end;
$$;

grant execute on function pg_temp.check(boolean, text), pg_temp.fails(text, text, text) to anon;

select pg_temp.anon();
select pg_temp.check(public.public_branding() = '{"logo_path": null}',
  'visitors see there is no logo yet');
select pg_temp.fails($$ select public.set_logo(null) $$, '42501', 'visitors cannot set it');
select pg_temp.fails($$ select * from public.branding $$, '42501', 'nor read the table');

select pg_temp.login(902);
select pg_temp.fails($$ select public.set_logo('logo/0123456789abcdef0123456789abcdef.png') $$,
  'not_allowed', 'others cannot set the logo');
select pg_temp.fails($$
  insert into storage.objects (bucket_id, name)
  values ('branding', 'logo/0123456789abcdef0123456789abcdef.png') $$,
  '42501', 'nor upload one');

select pg_temp.login(901);
insert into storage.objects (bucket_id, name)
values ('branding', 'logo/0123456789abcdef0123456789abcdef.png');
select pg_temp.fails($$
  insert into storage.objects (bucket_id, name) values ('branding', 'logo/x.svg') $$,
  '42501', 'admins upload only images with a random name');
select pg_temp.fails($$ select public.set_logo('../files/a.png') $$,
  'invalid_logo', 'the path must be an uploaded logo');
select pg_temp.check(
  public.set_logo('logo/0123456789abcdef0123456789abcdef.png') is null,
  'an admin sets the first logo');
select pg_temp.check(
  public.set_logo('logo/fedcba9876543210fedcba9876543210.webp')
    = 'logo/0123456789abcdef0123456789abcdef.png',
  'changing it hands back the old one to remove');
delete from storage.objects
where bucket_id = 'branding' and name = 'logo/0123456789abcdef0123456789abcdef.png';
select pg_temp.check(
  not exists (select 1 from storage.objects where bucket_id = 'branding'),
  'admins remove old logos');

select pg_temp.anon();
select pg_temp.check(
  public.public_branding()->>'logo_path' = 'logo/fedcba9876543210fedcba9876543210.webp',
  'visitors see the new logo');

select pg_temp.login(901);
select public.set_logo(null);
select pg_temp.check(public.public_branding()->>'logo_path' is null,
  'an admin can go back to the built-in logo');

reset role;
\echo 'all branding tests passed'
