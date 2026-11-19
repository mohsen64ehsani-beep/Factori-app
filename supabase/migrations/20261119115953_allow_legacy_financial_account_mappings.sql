alter table private.legacy_normalized_record_map
 drop constraint if exists legacy_normalized_record_map_legacy_collection_check,
 drop constraint if exists legacy_normalized_record_map_target_table_check;

alter table private.legacy_normalized_record_map
 add constraint legacy_normalized_record_map_legacy_collection_check
 check(legacy_collection = any(array[
  'cust','suppliers','prod','categories','warehouses','services','inv','serviceInv','fiscal',
  'pay','supplierPayments','expenses','otherincome','purchases','moneytransfers','accounts'
 ]::text[])),
 add constraint legacy_normalized_record_map_target_table_check
 check(target_table = any(array[
  'contacts','products','product_categories','warehouses','services','documents',
  'fiscal_periods','financial_transactions','cheques','account_transfers','financial_accounts'
 ]::text[]));
