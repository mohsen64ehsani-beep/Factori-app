-- 015: Read-only audit of legacy db:v2 records before normalized import.
-- DEVELOPMENT DRAFT ONLY. Does not copy, mutate, post, or delete business data.
begin;
create or replace function public.preview_legacy_normalization(p_business_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $fn$
declare
  v_collection text;
  v_total bigint;
  v_deleted bigint;
  v_bad_shape bigint;
  v_missing_id bigint;
  v_id_mismatch bigint;
  v_orphan_customer bigint:=0;
  v_orphan_product bigint:=0;
  v_orphan_supplier bigint:=0;
  v_collections jsonb:='[]'::jsonb;
  v_supported text[]:=array['cust','suppliers','prod','categories','services','warehouses','inv','serviceInv'];
  v_financial text[]:=array['pay','debt','creditors','creditorPayments','expenses','purchases',
    'supplierPayments','returns','wastage','stockMoves','warehouseStocks','transfers',
    'accounts','moneytransfers','opening','otherincome'];
begin
  if auth.uid() is null then
    raise exception using errcode='28000',message='Authentication required';
  end if;
  if not private.has_business_permission(p_business_id,'business.settings.manage') then
    raise exception using errcode='42501',message='Business administration permission required';
  end if;

  foreach v_collection in array v_supported loop
    select count(*),
      count(*) filter(where r.deleted_at is not null),
      count(*) filter(where r.deleted_at is null and jsonb_typeof(r.payload_public)<>'object'),
      count(*) filter(where r.deleted_at is null and case
        when v_collection in ('categories','services') then coalesce(r.payload_public->>'value','')=''
        else coalesce(r.payload_public->>'id','')='' end),
      count(*) filter(where r.deleted_at is null and case
        when v_collection in ('categories','services')
          then ('value:'||coalesce(r.payload_public->>'value','')) is distinct from r.legacy_id
        else r.payload_public->>'id' is distinct from r.legacy_id end)
    into v_total,v_deleted,v_bad_shape,v_missing_id,v_id_mismatch
    from private.business_state_records r
    where r.business_id=p_business_id and r.collection=v_collection;
    v_collections:=v_collections||jsonb_build_array(jsonb_build_object(
      'collection',v_collection,'total',v_total,'deleted',v_deleted,'active',v_total-v_deleted,
      'invalid_object_payloads',v_bad_shape,'missing_payload_ids',v_missing_id,
      'payload_id_mismatches',v_id_mismatch
    ));
  end loop;

  select count(*) into v_orphan_customer
  from private.business_state_records r
  where r.business_id=p_business_id and r.collection in ('inv','serviceInv')
    and r.deleted_at is null and coalesce(r.payload_public->>'cid','')<>''
    and not exists(select 1 from private.business_state_records c
      where c.business_id=r.business_id and c.collection='cust'
        and c.legacy_id=r.payload_public->>'cid' and c.deleted_at is null);

  select count(*) into v_orphan_product
  from private.business_state_records r
  cross join lateral jsonb_array_elements(
    case when jsonb_typeof(r.payload_public->'items')='array'
      then r.payload_public->'items' else '[]'::jsonb end
  ) item
  where r.business_id=p_business_id and r.collection='inv' and r.deleted_at is null
    and coalesce(item.value->>'pid','')<>''
    and not exists(select 1 from private.business_state_records p
      where p.business_id=r.business_id and p.collection='prod'
        and p.legacy_id=item.value->>'pid' and p.deleted_at is null);

  select count(*) into v_orphan_supplier
  from private.business_state_records r
  where r.business_id=p_business_id and r.collection='purchases' and r.deleted_at is null
    and coalesce(r.payload_public->>'supplierId','')<>''
    and not exists(select 1 from private.business_state_records s
      where s.business_id=r.business_id and s.collection='suppliers'
        and s.legacy_id=r.payload_public->>'supplierId' and s.deleted_at is null);

  return jsonb_build_object(
    'business_id',p_business_id,'mode','read_only_preflight','collections',v_collections,
    'orphan_invoice_customers',v_orphan_customer,'orphan_invoice_products',v_orphan_product,'orphan_purchase_suppliers',v_orphan_supplier,
    'financial_collections_deferred',to_jsonb(v_financial),
    'safe_to_import',v_orphan_customer=0 and v_orphan_product=0 and v_orphan_supplier=0 and not exists(
      select 1 from private.business_state_records r
      where r.business_id=p_business_id and r.collection=any(v_supported) and r.deleted_at is null
        and (jsonb_typeof(r.payload_public)<>'object'
          or case when r.collection in ('categories','services') then
            coalesce(r.payload_public->>'value','')=''
            or ('value:'||coalesce(r.payload_public->>'value','')) is distinct from r.legacy_id
          else coalesce(r.payload_public->>'id','')=''
            or r.payload_public->>'id' is distinct from r.legacy_id end)
    )
  );
end;
$fn$;
revoke all on function public.preview_legacy_normalization(uuid) from public,anon;
grant execute on function public.preview_legacy_normalization(uuid) to authenticated;
commit;
