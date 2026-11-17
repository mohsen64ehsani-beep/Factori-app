-- Synthetic Supabase Auth compatibility shim for disposable PostgreSQL 17 CI only.
-- Never use this file against a Supabase-hosted project.
do $$
begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
end
$$;

create schema if not exists auth;
create table if not exists auth.users (
  id uuid primary key
);

create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(pg_catalog.current_setting('request.jwt.claim.sub',true),'')::uuid;
$$;

grant usage on schema auth to authenticated;
grant execute on function auth.uid() to authenticated;
