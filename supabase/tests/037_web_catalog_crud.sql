-- 037: Authenticated catalog CRUD is permission-gated and never grants anonymous access.
begin;
do $$
declare
  t text;
  p text;
begin
  foreach t in array array['contacts','products','services'] loop
    if not (select relrowsecurity from pg_class where oid=to_regclass('public.'||t)) then
      raise exception 'RLS must remain enabled on public.%',t;
    end if;
    if has_table_privilege('anon','public.'||t,'SELECT')
      or has_table_privilege('anon','public.'||t,'INSERT')
      or has_table_privilege('anon','public.'||t,'UPDATE')
      or has_table_privilege('anon','public.'||t,'DELETE') then
      raise exception 'anon must not have direct privileges on public.%',t;
    end if;
    if has_table_privilege('authenticated','public.'||t,'DELETE') then
      raise exception 'Authenticated users must not hard-delete rows from public.%',t;
    end if;
  end loop;
  foreach p in array array[
    'contacts_web_insert','contacts_web_update',
    'products_web_insert','products_web_update',
    'services_web_insert','services_web_update'
  ] loop
    if not exists(select 1 from pg_policies where schemaname='public' and policyname=p and 'authenticated'=any(roles)) then
      raise exception 'Missing authenticated RLS policy %',p;
    end if;
  end loop;
  if not has_table_privilege('authenticated','public.contacts','INSERT')
    or not has_table_privilege('authenticated','public.contacts','UPDATE') then
    raise exception 'Authenticated contact CRUD grants are missing';
  end if;
  if not has_table_privilege('authenticated','public.products','INSERT')
    or not has_table_privilege('authenticated','public.products','UPDATE') then
    raise exception 'Authenticated product CRUD grants are missing';
  end if;
  if not has_table_privilege('authenticated','public.services','INSERT')
    or not has_table_privilege('authenticated','public.services','UPDATE') then
    raise exception 'Authenticated service CRUD grants are missing';
  end if;
end $$;
rollback;
