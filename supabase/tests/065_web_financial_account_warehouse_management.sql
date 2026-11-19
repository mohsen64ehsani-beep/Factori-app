begin;

do $$
declare
  v_oid regprocedure;
  v_def text;
begin
  if not has_function_privilege('authenticated','public.web_create_financial_account(uuid,text,text,text)','execute')
     or has_function_privilege('anon','public.web_create_financial_account(uuid,text,text,text)','execute') then
    raise exception 'Financial account RPC grants are incorrect';
  end if;
  if not has_function_privilege('authenticated','public.web_create_warehouse(uuid,text,text,text,text,boolean)','execute')
     or has_function_privilege('anon','public.web_create_warehouse(uuid,text,text,text,text,boolean)','execute') then
    raise exception 'Warehouse RPC grants are incorrect';
  end if;
  if not has_function_privilege('authenticated','public.web_import_legacy_financial_accounts(uuid)','execute')
     or has_function_privilege('anon','public.web_import_legacy_financial_accounts(uuid)','execute') then
    raise exception 'Legacy account import RPC grants are incorrect';
  end if;

  select p.oid::regprocedure into v_oid
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='web_create_financial_account';
  select pg_get_functiondef(v_oid::oid) into v_def;
  if v_def not ilike '%settings.manage%' or v_def not ilike '%write_legacy_master_record%'
     or v_def not ilike '%financial_account_ledger_map%' then
    raise exception 'Financial account RPC is missing permission, ledger mapping or mobile sync bridge';
  end if;

  select p.oid::regprocedure into v_oid
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='web_create_warehouse';
  select pg_get_functiondef(v_oid::oid) into v_def;
  if v_def not ilike '%inventory.adjust%' or v_def not ilike '%write_legacy_master_record%'
     or v_def not ilike '%legacy_normalized_record_map%' then
    raise exception 'Warehouse RPC is missing permission or mobile sync mapping';
  end if;

  if not exists(select 1 from pg_constraint where conrelid='private.legacy_normalized_record_map'::regclass and conname='legacy_normalized_record_map_legacy_collection_check' and pg_get_constraintdef(oid) ilike '%accounts%')
     or not exists(select 1 from pg_constraint where conrelid='private.legacy_normalized_record_map'::regclass and conname='legacy_normalized_record_map_target_table_check' and pg_get_constraintdef(oid) ilike '%financial_accounts%') then
    raise exception 'Legacy account mapping constraints are missing';
  end if;

  select p.oid::regprocedure into v_oid
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='web_import_legacy_financial_accounts';
  select pg_get_functiondef(v_oid::oid) into v_def;
  if v_def not ilike '%settings.manage%' or v_def not ilike '%financial_account_ledger_map%'
     or v_def not ilike '%source_fingerprint%' then
    raise exception 'Legacy account adoption is missing permission, ledger mapping or conflict detection';
  end if;
end;
$$;

rollback;
