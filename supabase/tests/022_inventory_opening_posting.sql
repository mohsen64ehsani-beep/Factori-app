-- 022: Opening stock creates FIFO layers and a balanced opening-equity journal.
begin;

do $test$
declare
 v_owner uuid:='98000000-0000-4000-8000-000000000001';
 v_outsider uuid:='98000000-0000-4000-8000-000000000002';
 v_business uuid:='99000000-0000-4000-8000-000000000001';
 v_other_business uuid:='99000000-0000-4000-8000-000000000002';
 v_warehouse uuid;
 v_product uuid;
 v_batch uuid;
 v_replay uuid;
 v_journal uuid;
 v_movement uuid;
 v_count integer;
 v_debit numeric;
 v_credit numeric;
 v_failed boolean:=false;
begin
 insert into auth.users(id,email,email_confirmed_at)
 values(v_owner,'opening-owner@example.test',now()),(v_outsider,'opening-outsider@example.test',now())
 on conflict(id) do nothing;
 insert into public.businesses(id,name,owner_user_id)
 values(v_business,'Opening business',v_owner),(v_other_business,'Other opening business',v_outsider)
 on conflict(id) do nothing;
 insert into public.business_members(business_id,user_id,role_code,status,joined_at)
 values(v_business,v_owner,'owner','active',now()),(v_other_business,v_outsider,'owner','active',now())
 on conflict(business_id,user_id) do nothing;

 insert into public.warehouses(business_id,name,code,is_default)
 values(v_business,'Opening warehouse','OPEN',true)
 returning id into v_warehouse;
 insert into public.products(business_id,name,sale_price,track_inventory,legacy_id)
 values(v_business,'Opening product',2000,true,'opening-product')
 returning id into v_product;

 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_batch:=public.post_inventory_opening(
  v_business,current_date,'Initial inventory',
  jsonb_build_array(jsonb_build_object(
   'product_id',v_product,'warehouse_id',v_warehouse,'quantity',5,'unit_cost',1000
  )),
  'opening-key-001'
 );
 v_replay:=public.post_inventory_opening(
  v_business,current_date,'Initial inventory',
  jsonb_build_array(jsonb_build_object(
   'product_id',v_product,'warehouse_id',v_warehouse,'quantity',5,'unit_cost',1000
  )),
  'opening-key-001'
 );
 if v_batch<>v_replay then raise exception 'Opening retry must return the original batch'; end if;

 select journal_entry_id into v_journal from public.inventory_opening_batches
 where business_id=v_business and id=v_batch;
 select stock_movement_id into v_movement from public.inventory_opening_items
 where business_id=v_business and batch_id=v_batch;
 if (select count(*) from public.stock_movements
   where business_id=v_business and id=v_movement and movement_type='opening' and quantity_delta=5)<>1 then
  raise exception 'Opening stock movement was not created';
 end if;
 if (select count(*) from public.inventory_cost_layers
   where business_id=v_business and source_movement_id=v_movement
     and quantity_in=5 and quantity_remaining=5 and unit_cost=1000)<>1 then
  raise exception 'Opening FIFO layer was not provisioned';
 end if;
 if (select purchase_cost from public.product_costs
   where business_id=v_business and product_id=v_product and source_type='opening')<>1000 then
  raise exception 'Opening cost history was not recorded';
 end if;
 select count(*),sum(debit),sum(credit) into v_count,v_debit,v_credit
 from public.journal_lines where business_id=v_business and journal_entry_id=v_journal;
 if v_count<>2 or v_debit<>5000 or v_credit<>5000 then
  raise exception 'Opening journal must debit inventory and credit opening equity';
 end if;
 if (select status from public.journal_entries where business_id=v_business and id=v_journal)<>'posted' then
  raise exception 'Opening journal must be posted';
 end if;

 v_failed:=false;
 begin
  perform public.post_inventory_opening(
   v_business,current_date,'Different request',
   jsonb_build_array(jsonb_build_object(
    'product_id',v_product,'warehouse_id',v_warehouse,'quantity',4,'unit_cost',1000
   )),
   'opening-key-001'
  );
 exception when unique_violation then v_failed:=true;
 end;
 if not v_failed then raise exception 'Changed opening request must not reuse an idempotency key'; end if;

 v_failed:=false;
 begin
  perform public.post_inventory_opening(
   v_business,current_date,'Duplicate opening',
   jsonb_build_array(jsonb_build_object(
    'product_id',v_product,'warehouse_id',v_warehouse,'quantity',1,'unit_cost',1000
   )),
   'opening-key-002'
  );
 exception when object_not_in_prerequisite_state then v_failed:=true;
 end;
 if not v_failed then raise exception 'Second opening for existing stock history must be rejected'; end if;

 v_failed:=false;
 perform set_config('request.jwt.claim.sub',v_outsider::text,true);
 begin
  perform public.post_inventory_opening(
   v_business,current_date,'Unauthorized',
   jsonb_build_array(jsonb_build_object(
    'product_id',v_product,'warehouse_id',v_warehouse,'quantity',1,'unit_cost',1000
   )),
   'opening-key-outsider'
  );
 exception when insufficient_privilege then v_failed:=true;
 end;
 if not v_failed then raise exception 'Cross-business opening must be denied'; end if;
end;
$test$;

rollback;
