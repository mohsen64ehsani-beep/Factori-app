begin;
do $$
declare v_oid regprocedure;v_def text;
begin
 if not has_function_privilege('authenticated','public.web_export_business_backup(uuid)','execute')
    or has_function_privilege('anon','public.web_export_business_backup(uuid)','execute') then
  raise exception 'Backup export RPC grants are incorrect';
 end if;
 select p.oid::regprocedure into v_oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='web_export_business_backup_v1';
 select pg_get_functiondef(v_oid::oid) into v_def;
 if v_def not ilike '%settings.manage%' or v_def not ilike '%contacts.ledger.read%'
    or v_def not ilike '%catalog.read%' or v_def not ilike '%legacy_public_records%' then
  raise exception 'Backup export is missing business permission gates or legacy records';
 end if;
 if v_def ilike '%payload_private%' or v_def ilike '%settings_json%' then
  raise exception 'Backup export must not expose private sync payloads or settings JSON';
 end if;
 select p.oid::regprocedure into v_oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='web_export_business_backup';
 select pg_get_functiondef(v_oid::oid) into v_def;
 if v_def not ilike '%web_export_business_backup_v1%' or v_def not ilike '%invoice_logo_url%' then
  raise exception 'Backup wrapper is missing base export or invoice branding';
 end if;
end;
$$;
rollback;
