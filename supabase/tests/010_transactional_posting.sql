-- Regression checks for transactional posting RPCs in migration 008.
begin;
do $$
declare
 v_fn text;
begin
 if to_regprocedure('public.post_journal_entry(uuid,date,text,uuid,jsonb,text)') is null then
  raise exception 'Transactional journal posting RPC is missing';
 end if;
 if to_regprocedure('public.post_stock_transfer(uuid,uuid,uuid,date,text,jsonb,text)') is null then
  raise exception 'Transactional stock transfer RPC is missing';
 end if;
 if has_function_privilege('anon','public.post_journal_entry(uuid,date,text,uuid,jsonb,text)','EXECUTE')
   or has_function_privilege('anon','public.post_stock_transfer(uuid,uuid,uuid,date,text,jsonb,text)','EXECUTE') then
  raise exception 'Anonymous role must not execute posting RPCs';
 end if;
 if not has_function_privilege('authenticated','public.post_journal_entry(uuid,date,text,uuid,jsonb,text)','EXECUTE')
   or not has_function_privilege('authenticated','public.post_stock_transfer(uuid,uuid,uuid,date,text,jsonb,text)','EXECUTE') then
  raise exception 'Authenticated role must execute posting RPCs';
 end if;
 v_fn:=pg_get_functiondef('public.post_journal_entry(uuid,date,text,uuid,jsonb,text)'::regprocedure);
 if position('accounting.journal.post' in v_fn)=0 or position('debit_total' in v_fn)=0
   or position('credit_total' in v_fn)=0 or position('status=''posted''' in v_fn)=0
   or position('pg_advisory_xact_lock' in v_fn)=0 or position('trunc(v_debit)' in v_fn)=0 then
  raise exception 'Journal posting permission, balance or posting checks are missing';
 end if;
 v_fn:=pg_get_functiondef('public.post_stock_transfer(uuid,uuid,uuid,date,text,jsonb,text)'::regprocedure);
 if position('inventory.transfer' in v_fn)=0 or position('for update' in lower(v_fn))=0
   or position('transfer_out' in v_fn)=0 or position('transfer_in' in v_fn)=0
   or position('insufficient' in lower(v_fn))=0
   or position('pg_advisory_xact_lock' in v_fn)=0 or position('track_inventory' in v_fn)=0
   or position('round(v_qty,4)' in v_fn)=0 then
  raise exception 'Stock transfer permission, locking, paired movements or stock check is missing';
 end if;
 if has_table_privilege('authenticated','public.stock_movements','INSERT')
   or has_table_privilege('authenticated','public.journal_entries','INSERT')
   or has_table_privilege('authenticated','public.journal_lines','INSERT') then
  raise exception 'Clients must not bypass posting RPCs with direct inserts';
 end if;
end $$;
rollback;
