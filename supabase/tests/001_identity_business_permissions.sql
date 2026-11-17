-- Disposable database checks for 001_identity_business_permissions.sql.
-- Run only after applying the draft in an isolated Supabase/Postgres test project.
begin;

do $$
declare
  t text;
  rel record;
begin
  foreach t in array array[
    'profiles','businesses','permission_catalog','business_members',
    'business_role_permissions','business_member_permission_overrides','business_settings'
  ] loop
    if to_regclass('public.'||t) is null then
      raise exception 'Missing required table public.%',t;
    end if;
    select c.relrowsecurity into rel
    from pg_class c where c.oid=to_regclass('public.'||t);
    if not rel.relrowsecurity then
      raise exception 'RLS is disabled on public.%',t;
    end if;
    if has_table_privilege('anon','public.'||t,'SELECT') then
      raise exception 'anon unexpectedly has SELECT on public.%',t;
    end if;
  end loop;

  if not has_function_privilege('authenticated','public.create_business(text)','EXECUTE') then
    raise exception 'authenticated cannot execute create_business';
  end if;
  if not has_function_privilege('authenticated','public.get_business_entitlements(uuid)','EXECUTE') then
    raise exception 'authenticated cannot execute get_business_entitlements';
  end if;
  if has_function_privilege('anon','public.create_business(text)','EXECUTE') then
    raise exception 'anon unexpectedly can execute create_business';
  end if;

  if not exists (
    select 1 from public.business_role_permissions
    where role_code='sales' and permission_code='sales.create' and allowed
  ) then raise exception 'sales role must be allowed to create sales drafts'; end if;

  if exists (
    select 1 from public.business_role_permissions
    where role_code='sales' and permission_code in ('catalog.cost.read','reports.profit.read') and allowed
  ) then raise exception 'sales role must not read cost or profit'; end if;

  if exists (
    select 1 from public.business_role_permissions
    where role_code='viewer' and allowed
      and permission_code not in ('business.read','contacts.read','catalog.read','sales.read','reports.basic.read')
  ) then raise exception 'viewer role has an unexpected write/sensitive permission'; end if;

  if not exists (
    select 1 from pg_trigger
    where tgname='factoori_auth_user_profile' and not tgisinternal
  ) then raise exception 'auth profile trigger is missing'; end if;
end $$;

rollback;
