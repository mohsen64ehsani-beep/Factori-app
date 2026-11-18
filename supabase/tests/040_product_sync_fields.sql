-- 040: SKU and inventory-tracking settings survive the shared mobile/web product bridge.
begin;
do $$
declare
 v_user uuid:='a0400000-0000-4000-8000-000000000001';
 v_business uuid;
 v_product uuid;
begin
 insert into auth.users(id,email,raw_user_meta_data)
 values(v_user,'factoori-product-fields-ci@example.invalid','{"display_name":"Product Fields CI"}'::jsonb)
 on conflict(id) do nothing;
 perform set_config('request.jwt.claim.sub',v_user::text,true);
 v_business:=public.create_business('Product Fields CI');
 v_product:=public.web_create_product(v_business,'Web SKU Product','WEB-SKU-40','بسته',4000,false,5,'400040');
 if not exists(select 1 from public.products where id=v_product and sku='WEB-SKU-40' and track_inventory=false and minimum_stock=5) then
  raise exception 'Web product fields were not saved to normalized products';
 end if;
 insert into private.business_state_records(business_id,collection,legacy_id,payload_public,updated_by)
 values(v_business,'prod','mobile-product-040','{"id":"mobile-product-040","n":"Mobile SKU Product","sku":"MOB-SKU-40","sell":4000,"minQty":5,"track_inventory":false}'::jsonb,v_user);
 if not exists(select 1 from public.products where business_id=v_business and legacy_id='mobile-product-040' and sku='MOB-SKU-40' and track_inventory=false) then
  raise exception 'Mobile product fields were not projected to normalized products';
 end if;
end $$;
rollback;
