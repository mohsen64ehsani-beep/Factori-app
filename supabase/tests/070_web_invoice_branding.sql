begin;
do $$
declare v_oid regprocedure;v_def text;
begin
 if not has_function_privilege('authenticated','public.web_update_invoice_branding(uuid,text,text,text,text)','execute')
    or has_function_privilege('anon','public.web_update_invoice_branding(uuid,text,text,text,text)','execute') then
  raise exception 'Invoice branding RPC grants are incorrect';
 end if;
 select p.oid::regprocedure into v_oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='web_update_invoice_branding';
 select pg_get_functiondef(v_oid::oid) into v_def;
 if v_def not ilike '%settings.manage%' or v_def not ilike '%https://%' or v_def not ilike '%invoice_template%' then
  raise exception 'Invoice branding RPC is missing permission or validation';
 end if;
 if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='business_settings' and column_name='invoice_logo_url')
    or not exists(select 1 from information_schema.columns where table_schema='public' and table_name='business_settings' and column_name='invoice_signature_url')
    or not exists(select 1 from information_schema.columns where table_schema='public' and table_name='business_settings' and column_name='invoice_template') then
  raise exception 'Invoice branding columns are missing';
 end if;
end;
$$;
rollback;
