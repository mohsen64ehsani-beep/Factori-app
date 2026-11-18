-- Regression assertions for mapped, atomic financial-account transfers.
begin;
do $$
declare v_fn text;
begin
 if to_regclass('public.financial_account_ledger_map') is null
   or to_regclass('public.account_transfers') is null then
  raise exception 'Account transfer mapping or transfer table is missing';
 end if;
 if not (select relrowsecurity from pg_class where oid='public.financial_account_ledger_map'::regclass)
   or not (select relrowsecurity from pg_class where oid='public.account_transfers'::regclass) then
  raise exception 'Account transfer tables must have RLS enabled';
 end if;
 if has_table_privilege('authenticated','public.account_transfers','INSERT')
   or has_table_privilege('authenticated','public.financial_account_ledger_map','INSERT') then
  raise exception 'Clients must not bypass account transfer RPCs';
 end if;
 if to_regprocedure('public.set_financial_account_ledger_map(uuid,uuid,uuid)') is null
   or to_regprocedure('public.post_account_transfer(uuid,uuid,uuid,numeric,date,text,text,uuid)') is null then
  raise exception 'Account transfer RPCs are missing';
 end if;
 if not has_function_privilege('authenticated','public.set_financial_account_ledger_map(uuid,uuid,uuid)','EXECUTE')
   or not has_function_privilege('authenticated','public.post_account_transfer(uuid,uuid,uuid,numeric,date,text,text,uuid)','EXECUTE')
   or has_function_privilege('anon','public.post_account_transfer(uuid,uuid,uuid,numeric,date,text,text,uuid)','EXECUTE') then
  raise exception 'Account transfer RPC grants are incorrect';
 end if;
 v_fn:=pg_get_functiondef('public.post_account_transfer(uuid,uuid,uuid,numeric,date,text,text,uuid)'::regprocedure);
 if position('payments.create' in v_fn)=0 or position('pg_advisory_xact_lock' in v_fn)=0
   or position('account_transfer_out' in v_fn)=0 or position('account_transfer_in' in v_fn)=0
   or position('journal_entries' in v_fn)=0 or position('journal_lines' in v_fn)=0
   or position('currency_code' in v_fn)=0 or position('for update' in lower(v_fn))=0
   or position('source_legacy_id' in v_fn)=0
   or position("'draft'" in v_fn)=0
   or position("set status='posted'" in v_fn)=0 then
  raise exception 'Account transfer permission, locking, currency or double-entry posting is missing';
 end if;
end $$;
rollback;
