-- Disposable checks for 004a. Run after migration 001 and before 005 in staging.
begin;
do $$
declare t text; r record;
begin
 foreach t in array array['sync_devices','sync_cursors','sync_operations','record_revisions','business_feature_limits','business_feature_usage'] loop
  if to_regclass('public.'||t) is null then raise exception 'Missing public.%',t; end if;
  select c.relrowsecurity into r from pg_class c where c.oid=to_regclass('public.'||t);
  if not r.relrowsecurity then raise exception 'RLS disabled on public.%',t; end if;
  if has_table_privilege('anon','public.'||t,'SELECT') then raise exception 'anon can read public.%',t; end if;
  if has_table_privilege('authenticated','public.'||t,'INSERT') then raise exception 'authenticated can insert public.% directly',t; end if;
 end loop;
 if not exists(select 1 from information_schema.columns
  where table_schema='public' and table_name='sync_operations' and column_name='request_fingerprint') then
  raise exception 'Sync operation request fingerprint column is missing';
 end if;
 if not exists(select 1 from pg_constraint where conrelid='public.sync_operations'::regclass and contype='u'
   and pg_get_constraintdef(oid) like '%business_id, device_id, operation_id%') then
  raise exception 'Sync operation idempotency unique constraint missing';
 end if;
 if position('for update' in lower(pg_get_functiondef('private.assert_feature_limit(uuid,text,integer)'::regprocedure)))=0 then
  raise exception 'Lifetime feature limit checks must lock the entitlement row';
 end if;
 if not exists(select 1 from information_schema.columns where table_schema='public'
  and table_name='business_members' and column_name='permission_version') then
  raise exception 'Business member permission version column missing';
 end if;
 if not exists(select 1 from information_schema.columns where table_schema='public'
  and table_name='sync_devices' and column_name='permission_version') then
  raise exception 'Sync device permission version column missing';
 end if;
 if not exists(select 1 from pg_trigger where tgname='business_members_permission_version' and not tgisinternal)
  or not exists(select 1 from pg_trigger where tgname='member_overrides_permission_version' and not tgisinternal) then
  raise exception 'Permission version triggers are missing';
 end if;
 if has_function_privilege('authenticated','private.assert_feature_limit(uuid,text,integer)','EXECUTE') then
  raise exception 'Authenticated users must not call private quota helpers directly';
 end if;
end $$;
rollback;
