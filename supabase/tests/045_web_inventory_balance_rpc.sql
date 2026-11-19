-- 045: Inventory balances are aggregated over the complete movement history.
begin;
do $$
declare v_user uuid:='a0450000-0000-4000-8000-000000000001';v_business uuid;v_product uuid;v_warehouse uuid;v_rows jsonb;
begin
 insert into auth.users(id,email,raw_user_meta_data) values(v_user,'factoori-stock-balance-ci@example.invalid','{"display_name":"Stock Balance CI"}'::jsonb) on conflict(id) do nothing;
 perform set_config('request.jwt.claim.sub',v_user::text,true);
 v_business:=public.create_business('Stock Balance CI');
 v_product:=public.web_create_product(v_business,'Balance Product 045','BAL045','عدد',1000,true,0,null);
 insert into public.warehouses(business_id,name,is_default,is_active) values(v_business,'Balance Warehouse 045',true,true) returning id into v_warehouse;
 insert into public.stock_movements(business_id,product_id,warehouse_id,movement_type,quantity_delta,movement_date,idempotency_key,created_by)
 values(v_business,v_product,v_warehouse,'opening',10,now(),'balance-045-a',v_user),
       (v_business,v_product,v_warehouse,'sale',-3,now(),'balance-045-b',v_user);
 v_rows:=public.web_list_inventory_balances(v_business);
 if (v_rows->0->>'quantity')::numeric<>7 then raise exception 'Inventory aggregate is not correct: %',v_rows; end if;
end $$;
rollback;