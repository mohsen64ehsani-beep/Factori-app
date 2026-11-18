-- Disposable checks for 011. Run after drafts 001 and 007 in isolated staging.
begin;
do $$
declare
  v_constraint text;
begin
  if not exists(select 1 from pg_constraint
    where conrelid='public.business_members'::regclass
      and conname='business_members_role_code_check'
      and pg_get_constraintdef(oid) like '%warehouse%') then
    raise exception 'Warehouse role missing from business_members';
  end if;
  if not exists(select 1 from pg_constraint
    where conrelid='public.business_role_permissions'::regclass
      and conname='business_role_permissions_role_code_check'
      and pg_get_constraintdef(oid) like '%warehouse%') then
    raise exception 'Warehouse role missing from business_role_permissions';
  end if;
  if not exists(select 1 from public.business_role_permissions
    where role_code='warehouse' and permission_code='inventory.read' and allowed) then
    raise exception 'Warehouse default inventory read permission missing';
  end if;
  if not exists(select 1 from public.business_role_permissions
    where role_code='warehouse' and permission_code='inventory.adjust' and allowed) then
    raise exception 'Warehouse default inventory adjustment permission missing';
  end if;
  if not exists(select 1 from public.business_role_permissions
    where role_code='warehouse' and permission_code='payments.create' and not allowed) then
    raise exception 'Warehouse must not receive payment permissions by default';
  end if;
  if position('service_role' in pg_get_functiondef(
    'public.provision_business_member(uuid,uuid,text,uuid,jsonb)'::regprocedure))=0 then
    raise exception 'Provisioning function must enforce service-role invocation';
  end if;
  if has_function_privilege('authenticated',
    'public.provision_business_member(uuid,uuid,text,uuid,jsonb)','EXECUTE') then
    raise exception 'Client roles must not directly provision members';
  end if;
  if not has_function_privilege('service_role',
    'public.provision_business_member(uuid,uuid,text,uuid,jsonb)','EXECUTE') then
    raise exception 'Service role provisioning grant missing';
  end if;
  if not has_function_privilege('authenticated',
    'public.get_business_member_permissions(uuid,uuid)','EXECUTE') then
    raise exception 'Effective permission lookup must be available to authenticated users';
  end if;
end $$;
rollback;
