begin;
do $$
declare v_oid regprocedure;v_def text;
begin
 if not has_function_privilege('authenticated','public.web_update_business_settings(uuid,text,integer,text,text,text,boolean,numeric,boolean)','execute')
    or has_function_privilege('anon','public.web_update_business_settings(uuid,text,integer,text,text,text,boolean,numeric,boolean)','execute') then
  raise exception 'Business settings RPC grants are incorrect';
 end if;
 select p.oid::regprocedure into v_oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='web_update_business_settings';
 select pg_get_functiondef(v_oid::oid) into v_def;
 if v_def not ilike '%settings.manage%' or v_def not ilike '%pg_timezone_names%'
    or v_def not ilike '%Currency and precision cannot change%'
    or v_def not ilike '%Inventory costing method cannot change%' then
  raise exception 'Business settings RPC is missing permission or historical integrity guards';
 end if;
end;
$$;
rollback;
