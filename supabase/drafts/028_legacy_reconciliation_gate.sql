-- 028: Read-only reconciliation gate before legacy cutover.
-- Returns counts only; never exposes payloads or mutates source/normalized data.
begin;

create or replace function public.reconcile_legacy_normalization(p_business_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
 v_collection text;
 v_collections jsonb:='[]'::jsonb;
 v_financial jsonb:='[]'::jsonb;
 v_financial_total bigint:=0;
 v_draft_documents bigint:=0;
 v_problem_count bigint:=0;
 v_other jsonb:='[]'::jsonb;
 v_other_total bigint:=0;
 v_total_active bigint:=0;
 v_mapped bigint:=0;
 v_unmapped bigint:=0;
 v_changed bigint:=0;
 v_conflicts bigint:=0;
 v_orphaned bigint:=0;
 v_needs_review bigint:=0;
 v_deleted bigint:=0;
begin
 if auth.uid() is null then
  raise exception using errcode='28000',message='Authentication required';
 end if;
 if not private.has_business_permission(p_business_id,'business.settings.manage') then
  raise exception using errcode='42501',message='Business administration permission required';
 end if;

 foreach v_collection in array array['cust','suppliers','prod','categories','services','warehouses','inv','serviceInv','fiscal'] loop
  select
   count(*) filter(where r.deleted_at is null),
   count(*) filter(where r.deleted_at is not null),
   count(*) filter(where r.deleted_at is null and m.id is null),
   count(*) filter(where r.deleted_at is null and m.import_status='mapped'
     and m.source_fingerprint=encode(extensions.digest(convert_to(r.payload_public::text,'UTF8'),'sha256'),'hex')
     and case r.collection
      when 'cust' then exists(select 1 from public.contacts x where x.business_id=p_business_id and x.id=m.normalized_id)
      when 'suppliers' then exists(select 1 from public.contacts x where x.business_id=p_business_id and x.id=m.normalized_id and x.contact_type in ('supplier','both'))
      when 'prod' then exists(select 1 from public.products x where x.business_id=p_business_id and x.id=m.normalized_id)
      when 'categories' then exists(select 1 from public.product_categories x where x.business_id=p_business_id and x.id=m.normalized_id)
      when 'services' then exists(select 1 from public.services x where x.business_id=p_business_id and x.id=m.normalized_id)
      when 'warehouses' then exists(select 1 from public.warehouses x where x.business_id=p_business_id and x.id=m.normalized_id)
      when 'inv' then exists(select 1 from public.documents x where x.business_id=p_business_id and x.id=m.normalized_id)
      when 'serviceInv' then exists(select 1 from public.documents x where x.business_id=p_business_id and x.id=m.normalized_id)
      when 'fiscal' then exists(select 1 from public.fiscal_periods x where x.business_id=p_business_id and x.id=m.normalized_id)
      else false end),
   count(*) filter(where r.deleted_at is null and m.import_status='mapped'
     and m.source_fingerprint is distinct from encode(extensions.digest(convert_to(r.payload_public::text,'UTF8'),'sha256'),'hex')),
   count(*) filter(where r.deleted_at is null and m.import_status='conflict'),
   count(*) filter(where r.deleted_at is null and (
     m.import_status='orphaned' or (m.import_status='mapped' and not case r.collection
      when 'cust' then exists(select 1 from public.contacts x where x.business_id=p_business_id and x.id=m.normalized_id)
      when 'suppliers' then exists(select 1 from public.contacts x where x.business_id=p_business_id and x.id=m.normalized_id and x.contact_type in ('supplier','both'))
      when 'prod' then exists(select 1 from public.products x where x.business_id=p_business_id and x.id=m.normalized_id)
      when 'categories' then exists(select 1 from public.product_categories x where x.business_id=p_business_id and x.id=m.normalized_id)
      when 'services' then exists(select 1 from public.services x where x.business_id=p_business_id and x.id=m.normalized_id)
      when 'warehouses' then exists(select 1 from public.warehouses x where x.business_id=p_business_id and x.id=m.normalized_id)
      when 'inv' then exists(select 1 from public.documents x where x.business_id=p_business_id and x.id=m.normalized_id)
      when 'serviceInv' then exists(select 1 from public.documents x where x.business_id=p_business_id and x.id=m.normalized_id)
      when 'fiscal' then exists(select 1 from public.fiscal_periods x where x.business_id=p_business_id and x.id=m.normalized_id)
      else false end))),
   count(*) filter(where r.deleted_at is null and m.import_status='needs_review')
  into v_total_active,v_deleted,v_unmapped,v_mapped,v_changed,v_conflicts,v_orphaned,v_needs_review
  from private.business_state_records r
  left join private.legacy_normalized_record_map m
   on m.business_id=r.business_id and m.legacy_collection=r.collection and m.legacy_id=r.legacy_id
  where r.business_id=p_business_id and r.collection=v_collection;

  v_collections:=v_collections||jsonb_build_array(jsonb_build_object(
   'collection',v_collection,'active',v_total_active,'deleted',v_deleted,
   'mapped_current',v_mapped,'unmapped',v_unmapped,'source_changed',v_changed,
   'conflicts',v_conflicts,'orphaned',v_orphaned,'needs_review',v_needs_review
  ));
  v_problem_count:=v_problem_count+v_unmapped+v_changed+v_conflicts+v_orphaned+v_needs_review+v_deleted;
 end loop;

 select coalesce(jsonb_agg(jsonb_build_object('collection',x.collection,'total',x.total) order by x.collection),'[]'::jsonb),
  coalesce(sum(x.total),0)
 into v_financial,v_financial_total
 from (
  select r.collection,count(*) as total
  from private.business_state_records r
  where r.business_id=p_business_id and r.collection=any(array[
   'pay','debt','creditors','creditorPayments','expenses','purchases','supplierPayments',
   'returns','wastage','stockMoves','warehouseStocks','transfers','accounts','moneytransfers',
   'opening','otherincome'
  ]) and r.deleted_at is null
  group by r.collection
 ) x;

 select coalesce(jsonb_agg(jsonb_build_object('collection',x.collection,'total',x.total) order by x.collection),'[]'::jsonb),
  coalesce(sum(x.total),0)
 into v_other,v_other_total
 from (
  select r.collection,count(*) as total
  from private.business_state_records r
  where r.business_id=p_business_id and r.collection=any(array[
   'bankAccounts','duedates','smsHistory'
  ]) and r.deleted_at is null
  group by r.collection
 ) x;

 select count(*) into v_draft_documents
 from private.legacy_normalized_record_map m
 join public.documents d on d.business_id=m.business_id and d.id=m.normalized_id
 where m.business_id=p_business_id and m.legacy_collection in ('inv','serviceInv')
  and m.target_table='documents' and m.import_status='mapped' and d.status='draft';

 return jsonb_build_object(
  'business_id',p_business_id,'mode','read_only_reconciliation',
  'collections',v_collections,'financial_collections_deferred',v_financial,
  'deferred_financial_records',v_financial_total,
  'other_collections_deferred',v_other,'deferred_other_records',v_other_total,
  'draft_documents_pending_review',v_draft_documents,
  'unresolved_source_or_mapping_rows',v_problem_count,
  'safe_to_cutover',v_problem_count=0 and v_financial_total=0 and v_other_total=0 and v_draft_documents=0
 );
end;
$$;

revoke all on function public.reconcile_legacy_normalization(uuid) from public,anon;
grant execute on function public.reconcile_legacy_normalization(uuid) to authenticated;

commit;
