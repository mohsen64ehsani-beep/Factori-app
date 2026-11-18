-- 026: Legacy goods invoices are imported as drafts, never posted as financial/stock facts.
begin;

do $test$
declare
 v_owner uuid:='a1000000-0000-4000-8000-000000000001';
 v_outsider uuid:='a1000000-0000-4000-8000-000000000002';
 v_business uuid:='a2000000-0000-4000-8000-000000000001';
 v_other_business uuid:='a2000000-0000-4000-8000-000000000002';
 v_generation uuid:='a3000000-0000-4000-8000-000000000001';
 v_result jsonb;
 v_document_id uuid;
 v_customer_id uuid;
 v_product_id uuid;
 v_failed boolean:=false;
begin
 insert into auth.users(id,email,email_confirmed_at)
 values(v_owner,'legacy-invoice-owner@example.test',now()),(v_outsider,'legacy-invoice-outsider@example.test',now())
 on conflict(id) do nothing;
 insert into public.businesses(id,name,owner_user_id)
 values(v_business,'Legacy invoice business',v_owner),(v_other_business,'Other legacy invoice business',v_outsider)
 on conflict(id) do nothing;
 insert into public.business_members(business_id,user_id,role_code,status,joined_at)
 values(v_business,v_owner,'owner','active',now()),(v_other_business,v_outsider,'owner','active',now())
 on conflict(business_id,user_id) do nothing;

 insert into private.business_state_records(business_id,collection,legacy_id,payload_public,payload_private,updated_by)
 values
  (v_business,'cust','legacy-customer','{"id":"legacy-customer","n":"Invoice customer"}','{}',v_owner),
  (v_business,'prod','legacy-product','{"id":"legacy-product","n":"Invoice product","sell":1500}','{"buy":900}',v_owner),
  (v_business,'warehouses','legacy-warehouse','{"id":"legacy-warehouse","name":"Invoice warehouse","address":"Unit 2"}','{}',v_owner),
  (v_business,'inv','legacy-invoice-1',
   '{"id":"legacy-invoice-1","no":501,"dt":"2026-01-15","cid":"legacy-customer","warehouseId":"legacy-warehouse","items":[{"pid":"legacy-product","n":"Invoice product snapshot","q":2,"p":1500}],"ds":100,"tx":9}',
   '{"items":[{"b":900}]}',v_owner);

 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_result:=public.import_legacy_reference_data(v_business,v_generation);
 if (v_result->>'imported_customers')::integer<>1
  or (v_result->>'imported_products')::integer<>1 then
  raise exception 'Customer/product prerequisite import failed: %',v_result;
 end if;
 v_result:=public.import_legacy_catalog_and_warehouses(v_business,v_generation);
 if (v_result->>'imported_warehouses')::integer<>1 then
  raise exception 'Warehouse prerequisite import failed: %',v_result;
 end if;

 v_result:=public.import_legacy_goods_invoice_drafts(v_business,v_generation);
 if (v_result->>'imported_drafts')::integer<>1 then
  raise exception 'Goods invoice draft import failed: %',v_result;
 end if;
 select normalized_id into v_document_id from private.legacy_normalized_record_map
 where business_id=v_business and legacy_collection='inv' and legacy_id='legacy-invoice-1';
 select normalized_id into v_customer_id from private.legacy_normalized_record_map
 where business_id=v_business and legacy_collection='cust' and legacy_id='legacy-customer';
 select normalized_id into v_product_id from private.legacy_normalized_record_map
 where business_id=v_business and legacy_collection='prod' and legacy_id='legacy-product';

 if not exists(select 1 from public.documents where business_id=v_business and id=v_document_id
  and document_type='goods_sale' and status='draft' and document_number='501'
  and contact_id=v_customer_id and total_amount=3162) then
  raise exception 'Normalized draft header or calculated totals are incorrect';
 end if;
 if not exists(select 1 from public.document_items where business_id=v_business and document_id=v_document_id
  and product_id=v_product_id and quantity=2 and unit_price=1500
  and description_snapshot='Invoice product snapshot' and tax_rate_snapshot=9) then
  raise exception 'Normalized draft item snapshot is incorrect';
 end if;
 if exists(select 1 from public.document_item_costs where business_id=v_business and document_item_id in
  (select id from public.document_items where business_id=v_business and document_id=v_document_id))
  or exists(select 1 from public.stock_movements where business_id=v_business)
  or exists(select 1 from public.journal_entries where business_id=v_business)
  or exists(select 1 from public.document_postings where business_id=v_business) then
  raise exception 'Draft import must not create costs, stock or posted accounting';
 end if;

 v_result:=public.import_legacy_goods_invoice_drafts(v_business,v_generation);
 if (v_result->>'unchanged')::integer<>1 then
  raise exception 'Repeated invoice import must be a no-op: %',v_result;
 end if;

 update private.business_state_records
 set payload_public=payload_public||'{"ds":200}'::jsonb
 where business_id=v_business and collection='inv' and legacy_id='legacy-invoice-1';
 v_result:=public.import_legacy_goods_invoice_drafts(v_business,'a3000000-0000-4000-8000-000000000002');
 if (v_result->>'conflicts')::integer<>1 then
  raise exception 'Changed invoice source must be flagged, not overwritten: %',v_result;
 end if;
 if (select discount_amount from public.documents where business_id=v_business and id=v_document_id)<>100 then
  raise exception 'Changed legacy invoice must not overwrite normalized draft';
 end if;

 v_failed:=false;
 perform set_config('request.jwt.claim.sub',v_outsider::text,true);
 begin
  perform public.import_legacy_goods_invoice_drafts(v_business,'a3000000-0000-4000-8000-000000000003');
 exception when insufficient_privilege then v_failed:=true;
 end;
 if not v_failed then raise exception 'Cross-business invoice import must be denied'; end if;
end;
$test$;

rollback;
