-- 027: Legacy service invoices become draft documents; costs and initial payments stay deferred.
begin;

do $test$
declare
 v_owner uuid:='a4000000-0000-4000-8000-000000000001';
 v_outsider uuid:='a4000000-0000-4000-8000-000000000002';
 v_business uuid:='a5000000-0000-4000-8000-000000000001';
 v_other_business uuid:='a5000000-0000-4000-8000-000000000002';
 v_generation uuid:='a6000000-0000-4000-8000-000000000001';
 v_result jsonb;
 v_document_id uuid;
 v_customer_id uuid;
 v_service_id uuid;
 v_failed boolean:=false;
begin
 insert into auth.users(id,email,email_confirmed_at)
 values(v_owner,'legacy-service-owner@example.test',now()),(v_outsider,'legacy-service-outsider@example.test',now())
 on conflict(id) do nothing;
 insert into public.businesses(id,name,owner_user_id)
 values(v_business,'Legacy service invoice business',v_owner),(v_other_business,'Other service invoice business',v_outsider)
 on conflict(id) do nothing;
 insert into public.business_members(business_id,user_id,role_code,status,joined_at)
 values(v_business,v_owner,'owner','active',now()),(v_other_business,v_outsider,'owner','active',now())
 on conflict(business_id,user_id) do nothing;

 insert into private.business_state_records(business_id,collection,legacy_id,payload_public,payload_private,updated_by)
 values
  (v_business,'cust','service-customer','{"id":"service-customer","n":"Service customer"}','{}',v_owner),
  (v_business,'services','value:Installation','{"value":"Installation"}','{}',v_owner),
  (v_business,'serviceInv','service-invoice-1',
   '{"id":"service-invoice-1","no":701,"dt":"2026-02-10","cid":"service-customer","items":[{"desc":"Installation","qty":2,"price":2000}],"discount":500}',
   '{"items":[{"cost":800}],"costTotal":800,"bankAccountId":"legacy-bank"}',v_owner),
  (v_business,'pay','service-payment-1',
   '{"id":"service-payment-1","source":"service_invoice","invoiceId":"service-invoice-1","amt":1000}',
   '{}',v_owner);

 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_result:=public.import_legacy_reference_data(v_business,v_generation);
 if (v_result->>'imported_customers')::integer<>1 then
  raise exception 'Customer prerequisite import failed: %',v_result;
 end if;
 v_result:=public.import_legacy_catalog_and_warehouses(v_business,v_generation);
 if (v_result->>'imported_services')::integer<>1 then
  raise exception 'Service prerequisite import failed: %',v_result;
 end if;

 v_result:=public.import_legacy_service_invoice_drafts(v_business,v_generation);
 if (v_result->>'imported_drafts')::integer<>1 then
  raise exception 'Service invoice draft import failed: %',v_result;
 end if;
 select normalized_id into v_document_id from private.legacy_normalized_record_map
 where business_id=v_business and legacy_collection='serviceInv' and legacy_id='service-invoice-1';
 select normalized_id into v_customer_id from private.legacy_normalized_record_map
 where business_id=v_business and legacy_collection='cust' and legacy_id='service-customer';
 select normalized_id into v_service_id from private.legacy_normalized_record_map
 where business_id=v_business and legacy_collection='services' and legacy_id='value:Installation';

 if not exists(select 1 from public.documents where business_id=v_business and id=v_document_id
  and document_type='service_sale' and status='draft' and document_number='701'
  and contact_id=v_customer_id and total_amount=3500) then
  raise exception 'Normalized service draft header or totals are incorrect';
 end if;
 if not exists(select 1 from public.document_items where business_id=v_business and document_id=v_document_id
  and service_id=v_service_id and item_type='service' and quantity=2 and unit_price=2000
  and description_snapshot='Installation') then
  raise exception 'Normalized service draft item is incorrect';
 end if;
 if exists(select 1 from public.financial_transactions where business_id=v_business)
  or exists(select 1 from public.journal_entries where business_id=v_business)
  or exists(select 1 from public.document_item_costs where business_id=v_business)
  or exists(select 1 from public.stock_movements where business_id=v_business) then
  raise exception 'Service draft import must not create payments, journals, costs or stock';
 end if;

 v_result:=public.import_legacy_service_invoice_drafts(v_business,v_generation);
 if (v_result->>'unchanged')::integer<>1 then
  raise exception 'Repeated service invoice import must be a no-op: %',v_result;
 end if;

 update private.business_state_records
 set payload_public=payload_public||'{"discount":600}'::jsonb
 where business_id=v_business and collection='serviceInv' and legacy_id='service-invoice-1';
 v_result:=public.import_legacy_service_invoice_drafts(v_business,'a6000000-0000-4000-8000-000000000002');
 if (v_result->>'conflicts')::integer<>1 then
  raise exception 'Changed service invoice source must be flagged as a conflict: %',v_result;
 end if;
 if (select discount_amount from public.documents where business_id=v_business and id=v_document_id)<>500 then
  raise exception 'Changed legacy service invoice must not overwrite normalized draft';
 end if;

 v_failed:=false;
 perform set_config('request.jwt.claim.sub',v_outsider::text,true);
 begin
  perform public.import_legacy_service_invoice_drafts(v_business,'a6000000-0000-4000-8000-000000000003');
 exception when insufficient_privilege then v_failed:=true;
 end;
 if not v_failed then raise exception 'Cross-business service invoice import must be denied'; end if;
end;
$test$;

rollback;
