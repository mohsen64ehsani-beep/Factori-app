-- 063: Service catalog policies are scoped to authenticated users; writes use approved RPCs.
begin;
do $$
begin
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='services' and policyname='services_web_update' and 'authenticated'=any(roles)) then
  raise exception 'Service update policy must target authenticated users';
 end if;
 if has_table_privilege('anon','public.services','INSERT') or has_table_privilege('anon','public.services','UPDATE') then
  raise exception 'Anonymous service writes must remain denied';
 end if;
 if has_table_privilege('authenticated','public.services','INSERT') or has_table_privilege('authenticated','public.services','UPDATE') then
  raise exception 'Direct service writes must remain revoked; use the validated RPC';
 end if;
 if not has_function_privilege('authenticated','public.web_create_service(uuid,text,text,numeric)','EXECUTE') then
  raise exception 'Authenticated service creation RPC is missing';
 end if;
end $$;
rollback;
