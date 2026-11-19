begin;
do $$
declare v_def text;v_oid regprocedure;
begin
 if not has_function_privilege('authenticated','public.web_create_due_date(uuid,date,date,text,text,numeric,text,text)','execute')
    or has_function_privilege('anon','public.web_create_due_date(uuid,date,date,text,text,numeric,text,text)','execute') then
  raise exception 'Due-date create grants are incorrect';
 end if;
 if not has_function_privilege('authenticated','public.web_set_due_date_status(uuid,uuid,text)','execute')
    or has_function_privilege('anon','public.web_set_due_date_status(uuid,uuid,text)','execute') then
  raise exception 'Due-date status grants are incorrect';
 end if;
 if not has_function_privilege('authenticated','public.web_create_fiscal_period(uuid,text,date,date)','execute')
    or has_function_privilege('anon','public.web_create_fiscal_period(uuid,text,date,date)','execute') then
  raise exception 'Fiscal period create grants are incorrect';
 end if;
 if not has_function_privilege('authenticated','public.web_set_fiscal_period_status(uuid,uuid,text)','execute')
    or has_function_privilege('anon','public.web_set_fiscal_period_status(uuid,uuid,text)','execute') then
  raise exception 'Fiscal period status grants are incorrect';
 end if;
 if not has_table_privilege('authenticated','public.business_due_dates','select')
    or has_table_privilege('anon','public.business_due_dates','select') then
  raise exception 'Due-date table read grants are incorrect';
 end if;
 if not (select relrowsecurity from pg_class where oid='public.business_due_dates'::regclass) then
  raise exception 'Due-date table must have RLS enabled';
 end if;

 select p.oid::regprocedure into v_oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='web_create_due_date';
 select pg_get_functiondef(v_oid::oid) into v_def;
 if v_def not ilike '%payments.create%' or v_def not ilike '%write_legacy_master_record%' then
  raise exception 'Due-date RPC is missing permission or Android sync';
 end if;
 select p.oid::regprocedure into v_oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='web_create_fiscal_period';
 select pg_get_functiondef(v_oid::oid) into v_def;
 if v_def not ilike '%settings.manage%' or v_def not ilike '%daterange%' or v_def not ilike '%legacy_normalized_record_map%' then
  raise exception 'Fiscal-period create RPC is missing permission, overlap guard or sync mapping';
 end if;
 select p.oid::regprocedure into v_oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='web_set_fiscal_period_status';
 select pg_get_functiondef(v_oid::oid) into v_def;
 if v_def not ilike '%Draft documents exist%' or v_def not ilike '%Draft journal entries exist%' or v_def not ilike '%write_legacy_master_record%' then
  raise exception 'Fiscal-period close RPC is missing draft guards or Android sync';
 end if;
end;
$$;
rollback;
