-- 024: Legacy customer/product import is idempotent, tenant-scoped and excludes costs/stock.
begin;

do $test$
declare
 v_owner uuid:='9a000000-0000-4000-8000-000000000001';
 v_outsider uuid:='9a000000-0000-4000-8000-000000000002';
 v_business uuid:='9b000000-0000-4000-8000-000000000001';
 v_other_business uuid:='9b000000-0000-4000-8000-000000000002';
 v_generation uuid:='9c000000-0000-4000-8000-000000000001';
 v_result jsonb;
 v_customer_id uuid;
 v_product_id uuid;
 v_failed boolean:=false;
begin
 insert into auth.users(id,email,email_confirmed_at)
 values(v_owner,'legacy-import-owner@example.test',now()),(v_outsider,'legacy-import-outsider@example.test',now())
 on conflict(id) do nothing;
 insert into public.businesses(id,name,owner_user_id)
 values(v_business,'Legacy import business',v_owner),(v_other_business,'Other legacy business',v_outsider)
 on conflict(id) do nothing;
 insert into public.business_members(business_id,user_id,role_code,status,joined_at)
 values(v_business,v_owner,'owner','active',now()),(v_other_business,v_outsider,'owner','active',now())
 on conflict(business_id,user_id) do nothing;

 insert into private.business_state_records(business_id,collection,legacy_id,payload_public,payload_private,updated_by)
 values
  (v_business,'cust','old-customer-1',
   '{"id":"old-customer-1","n":"Customer One","ph":"09120000000","ad":"Tehran","code":"123"}',
   '{}',v_owner),
  (v_business,'prod','old-product-1',
   '{"id":"old-product-1","n":"Product One","sell":2500,"qty":80,"barcode":"legacy-barcode-1","minQty":3}',
   '{"buy":1400}',v_owner),
  (v_business,'prod','old-product-deleted',
   '{"id":"old-product-deleted","n":"Deleted Product","sell":100}',
   '{}',v_owner);
 update private.business_state_records set deleted_at=now()
 where business_id=v_business and legacy_id='old-product-deleted';

 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_result:=public.import_legacy_reference_data(v_business,v_generation);
 if (v_result->>'imported_customers')::integer<>1
  or (v_result->>'imported_products')::integer<>1
  or (v_result->>'deleted_source_rows_skipped')::integer<>1 then
  raise exception 'Reference import counts are incorrect: %',v_result;
 end if;
 select normalized_id into v_customer_id from private.legacy_normalized_record_map
 where business_id=v_business and legacy_collection='cust' and legacy_id='old-customer-1';
 select normalized_id into v_product_id from private.legacy_normalized_record_map
 where business_id=v_business and legacy_collection='prod' and legacy_id='old-product-1';
 if not exists(select 1 from public.contacts where business_id=v_business and id=v_customer_id
  and contact_type='customer' and name='Customer One' and code='123') then
  raise exception 'Customer fields were not normalized correctly';
 end if;
 if not exists(select 1 from public.products where business_id=v_business and id=v_product_id
  and sale_price=2500 and minimum_stock=3 and track_inventory=true) then
  raise exception 'Product fields were not normalized correctly';
 end if;
 if exists(select 1 from public.stock_movements where business_id=v_business and product_id=v_product_id)
  or exists(select 1 from public.inventory_cost_layers where business_id=v_business and product_id=v_product_id)
  or exists(select 1 from public.product_costs where business_id=v_business and product_id=v_product_id) then
  raise exception 'Legacy quantity or private buy cost must not be imported by reference importer';
 end if;

 v_result:=public.import_legacy_reference_data(v_business,v_generation);
 if (v_result->>'unchanged')::integer<>2 then
  raise exception 'Repeated identical import must be a no-op: %',v_result;
 end if;

 update private.business_state_records
 set payload_public=payload_public||'{"sell":3000}'::jsonb
 where business_id=v_business and collection='prod' and legacy_id='old-product-1';
 v_result:=public.import_legacy_reference_data(v_business,'9c000000-0000-4000-8000-000000000002');
 if (v_result->>'conflicts')::integer<>1 then
  raise exception 'Changed source must be flagged as a conflict, not overwritten: %',v_result;
 end if;
 if (select sale_price from public.products where business_id=v_business and id=v_product_id)<>2500 then
  raise exception 'Changed legacy source must not silently overwrite normalized product';
 end if;

 v_failed:=false;
 perform set_config('request.jwt.claim.sub',v_outsider::text,true);
 begin
  perform public.import_legacy_reference_data(v_business,'9c000000-0000-4000-8000-000000000003');
 exception when insufficient_privilege then v_failed:=true;
 end;
 if not v_failed then raise exception 'Cross-business import must be denied'; end if;
end;
$test$;

rollback;
