-- 047: Stock movement bridge does not assume a legacy_id column on normalized warehouses.
begin;
do $$
declare v_user uuid:='a0470000-0000-4000-8000-000000000001';v_business uuid;v_product uuid;v_warehouse uuid;v_movement uuid;v_payload jsonb;
begin
 insert into auth.users(id,email,raw_user_meta_data) values(v_user,'factoori-stock-bridge-fix-ci@example.invalid','{"display_name":"Stock Bridge Fix CI"}'::jsonb) on conflict(id) do nothing;
 perform set_config('request.jwt.claim.sub',v_user::text,true);
 v_business:=public.create_business('Stock Bridge Fix CI');
 v_product:=public.web_create_product(v_business,'Stock Bridge Product 047','SB047','عدد',1000,true,0,null);
 insert into public.warehouses(business_id,name,is_default,is_active) values(v_business,'Stock Bridge Warehouse 047',true,true) returning id into v_warehouse;
 insert into public.stock_movements(business_id,product_id,warehouse_id,movement_type,quantity_delta,movement_date,idempotency_key,created_by)
 values(v_business,v_product,v_warehouse,'opening',5,now(),'stock-bridge-047',v_user) returning id into v_movement;
 select payload_public into v_payload from private.business_state_records where business_id=v_business and collection='stockMoves' and legacy_id=v_movement::text;
 if v_payload is null or (v_payload->>'after')::numeric<>5 then raise exception 'Stock movement was not mirrored after warehouse compatibility fix'; end if;
end $$;
rollback;
