-- 025: Import legacy categories, service names and warehouses without stock or finance.
begin;

do $test$
declare
 v_owner uuid:='9d000000-0000-4000-8000-000000000001';
 v_outsider uuid:='9d000000-0000-4000-8000-000000000002';
 v_business uuid:='9e000000-0000-4000-8000-000000000001';
 v_other_business uuid:='9e000000-0000-4000-8000-000000000002';
 v_generation uuid:='9f000000-0000-4000-8000-000000000001';
 v_result jsonb;
 v_product_id uuid;
 v_category_id uuid;
 v_warehouse_id uuid;
 v_service_id uuid;
 v_failed boolean:=false;
begin
 insert into auth.users(id,email,email_confirmed_at)
 values(v_owner,'legacy-catalog-owner@example.test',now()),(v_outsider,'legacy-catalog-outsider@example.test',now())
 on conflict(id) do nothing;
 insert into public.businesses(id,name,owner_user_id)
 values(v_business,'Legacy catalog business',v_owner),(v_other_business,'Other legacy catalog business',v_outsider)
 on conflict(id) do nothing;
 insert into public.business_members(business_id,user_id,role_code,status,joined_at)
 values(v_business,v_owner,'owner','active',now()),(v_other_business,v_outsider,'owner','active',now())
 on conflict(business_id,user_id) do nothing;

 insert into private.business_state_records(business_id,collection,legacy_id,payload_public,payload_private,updated_by)
 values
  (v_business,'prod','legacy-category-product',
   '{"id":"legacy-category-product","n":"Hammer","sell":500,"category":"Hardware","qty":17}',
   '{"buy":250}',v_owner),
  (v_business,'categories','value:Hardware','{"value":"Hardware"}','{}',v_owner),
  (v_business,'services','value:Installation','{"value":"Installation"}','{}',v_owner),
  (v_business,'warehouses','aaaaaaaa-0000-4000-8000-000000000001',
   '{"id":"aaaaaaaa-0000-4000-8000-000000000001","name":"Main warehouse","address":"Unit 1"}','{}',v_owner);

 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_result:=public.import_legacy_reference_data(v_business,v_generation);
 if (v_result->>'imported_products')::integer<>1 then
  raise exception 'Prerequisite product import failed: %',v_result;
 end if;
 v_result:=public.import_legacy_catalog_and_warehouses(v_business,v_generation);
 if (v_result->>'imported_categories')::integer<>1
  or (v_result->>'imported_services')::integer<>1
  or (v_result->>'imported_warehouses')::integer<>1
  or (v_result->>'products_categorized')::integer<>1 then
  raise exception 'Catalog/warehouse import counts are incorrect: %',v_result;
 end if;

 select normalized_id into v_product_id from private.legacy_normalized_record_map
 where business_id=v_business and legacy_collection='prod' and legacy_id='legacy-category-product';
 select normalized_id into v_category_id from private.legacy_normalized_record_map
 where business_id=v_business and legacy_collection='categories' and legacy_id='value:Hardware';
 select normalized_id into v_service_id from private.legacy_normalized_record_map
 where business_id=v_business and legacy_collection='services' and legacy_id='value:Installation';
 select normalized_id into v_warehouse_id from private.legacy_normalized_record_map
 where business_id=v_business and legacy_collection='warehouses'
  and legacy_id='aaaaaaaa-0000-4000-8000-000000000001';

 if not exists(select 1 from public.products where business_id=v_business and id=v_product_id and category_id=v_category_id) then
  raise exception 'Imported product was not linked to its exact legacy category';
 end if;
 if not exists(select 1 from public.product_categories where business_id=v_business and id=v_category_id and name='Hardware') then
  raise exception 'Category was not normalized';
 end if;
 if not exists(select 1 from public.services where business_id=v_business and id=v_service_id and name='Installation') then
  raise exception 'Legacy service name was not normalized';
 end if;
 if not exists(select 1 from public.warehouses where business_id=v_business and id=v_warehouse_id
  and name='Main warehouse' and is_default=true) then
  raise exception 'Legacy warehouse was not normalized as the initial default';
 end if;
 if exists(select 1 from public.stock_movements where business_id=v_business)
  or exists(select 1 from public.inventory_cost_layers where business_id=v_business)
  or exists(select 1 from public.product_costs where business_id=v_business) then
  raise exception 'Warehouse import must not create stock, FIFO layers or costs';
 end if;

 v_result:=public.import_legacy_catalog_and_warehouses(v_business,v_generation);
 if (v_result->>'unchanged')::integer<>3 then
  raise exception 'Identical catalog/warehouse import must be a no-op: %',v_result;
 end if;

 update private.business_state_records
 set payload_public=payload_public||'{"name":"Renamed warehouse"}'::jsonb
 where business_id=v_business and collection='warehouses'
  and legacy_id='aaaaaaaa-0000-4000-8000-000000000001';
 v_result:=public.import_legacy_catalog_and_warehouses(v_business,'9f000000-0000-4000-8000-000000000002');
 if (v_result->>'conflicts')::integer<>1 then
  raise exception 'Changed warehouse source must be flagged, not overwritten: %',v_result;
 end if;
 if (select name from public.warehouses where business_id=v_business and id=v_warehouse_id)<>'Main warehouse' then
  raise exception 'Changed legacy warehouse must not overwrite normalized data';
 end if;

 v_failed:=false;
 perform set_config('request.jwt.claim.sub',v_outsider::text,true);
 begin
  perform public.import_legacy_catalog_and_warehouses(v_business,'9f000000-0000-4000-8000-000000000003');
 exception when insufficient_privilege then v_failed:=true;
 end;
 if not v_failed then raise exception 'Cross-business catalog import must be denied'; end if;
end;
$test$;

rollback;
