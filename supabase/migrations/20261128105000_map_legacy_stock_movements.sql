begin;

alter table private.legacy_normalized_record_map
 drop constraint if exists legacy_normalized_record_map_legacy_collection_check,
 add constraint legacy_normalized_record_map_legacy_collection_check
 check (legacy_collection = any (array[
  'cust','suppliers','prod','categories','warehouses','services','inv','serviceInv',
  'fiscal','pay','supplierPayments','expenses','otherincome','purchases',
  'moneytransfers','accounts','stockMoves'
 ]::text[]));

alter table private.legacy_normalized_record_map
 drop constraint if exists legacy_normalized_record_map_target_table_check,
 add constraint legacy_normalized_record_map_target_table_check
 check (target_table = any (array[
  'contacts','products','product_categories','warehouses','services','documents',
  'fiscal_periods','financial_transactions','cheques','account_transfers',
  'financial_accounts','stock_movements'
 ]::text[]));

insert into private.legacy_normalized_record_map(
 business_id,legacy_collection,legacy_id,target_table,normalized_id,
 source_fingerprint,import_status,import_generation,created_by
)
select r.business_id,'stockMoves',r.legacy_id,'stock_movements',sm.id,
 encode(extensions.digest(convert_to(r.payload_public::text,'UTF8'),'sha256'),'hex'),
 'mapped',gen_random_uuid(),null
from private.business_state_records r
join public.stock_movements sm
 on sm.business_id=r.business_id and sm.id::text=r.legacy_id
where r.collection='stockMoves' and r.deleted_at is null
on conflict (business_id,legacy_collection,legacy_id) do update
 set target_table='stock_movements',
     normalized_id=excluded.normalized_id,
     source_fingerprint=excluded.source_fingerprint,
     import_status='mapped',
     import_generation=excluded.import_generation,
     updated_at=now();

commit;