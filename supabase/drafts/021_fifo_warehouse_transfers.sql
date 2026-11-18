-- 021: Preserve FIFO cost layers when transferring stock between warehouses.
-- Replaces the earlier quantity-only transfer RPC; no balances are synthesized.
begin;

create or replace function public.post_stock_transfer(
 p_business_id uuid,
 p_from_warehouse_id uuid,
 p_to_warehouse_id uuid,
 p_transfer_date date,
 p_note text,
 p_items jsonb,
 p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
 v_user uuid:=auth.uid();
 v_transfer_id uuid;
 v_item jsonb;
 v_product_id uuid;
 v_qty numeric(30,6);
 v_stock_available numeric(20,4);
 v_layer_available numeric(20,4);
 v_line integer:=0;
 v_fingerprint text;
 v_existing_fingerprint text;
 v_existing_id uuid;
 v_item_count integer;
 v_canonical_items jsonb:='[]'::jsonb;
 v_from_movement_id uuid;
 v_to_movement_id uuid;
 v_remaining numeric(20,4);
 v_take numeric(20,4);
 v_layer record;
 v_cost_total numeric(30,0);
begin
 if v_user is null then
  raise exception using errcode='28000',message='Authentication required';
 end if;
 if not private.has_business_permission(p_business_id,'inventory.transfer') then
  raise exception using errcode='42501',message='Inventory transfer is not permitted';
 end if;
 if p_from_warehouse_id is null or p_to_warehouse_id is null or p_from_warehouse_id=p_to_warehouse_id
   or p_transfer_date is null or p_idempotency_key is null
   or length(p_idempotency_key) not between 8 and 160 then
  raise exception using errcode='22023',message='Invalid transfer header or idempotency key';
 end if;
 if not exists(select 1 from public.warehouses w where w.business_id=p_business_id and w.id=p_from_warehouse_id and w.is_active)
   or not exists(select 1 from public.warehouses w where w.business_id=p_business_id and w.id=p_to_warehouse_id and w.is_active) then
  raise exception using errcode='22023',message='Source or destination warehouse is missing or inactive';
 end if;
 perform 1 from public.warehouses w
 where w.business_id=p_business_id and w.id in (p_from_warehouse_id,p_to_warehouse_id)
 order by w.id for update;

 if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 100 then
  raise exception using errcode='22023',message='Transfer must contain between 1 and 100 items';
 end if;
 if exists(select 1 from jsonb_array_elements(p_items) e
   group by nullif(e.value->>'product_id','')::uuid having count(*)>1) then
  raise exception using errcode='22023',message='Duplicate products must be combined into one transfer line';
 end if;

 for v_item in select value from jsonb_array_elements(p_items) loop
  if jsonb_typeof(v_item)<>'object' then
   raise exception using errcode='22023',message='Transfer line must be an object';
  end if;
  v_product_id:=nullif(v_item->>'product_id','')::uuid;
  v_qty:=coalesce((v_item->>'quantity')::numeric,0);
  if v_product_id is null or v_qty::text in ('NaN','Infinity','-Infinity')
    or v_qty<=0 or v_qty>1000000000 or round(v_qty,4)<>v_qty then
   raise exception using errcode='22023',message='Invalid transfer product or quantity';
  end if;
  v_canonical_items:=v_canonical_items||jsonb_build_array(
    jsonb_build_object('product_id',v_product_id,'quantity',v_qty::numeric(20,4))
  );
 end loop;

 v_fingerprint:=md5(jsonb_build_array(p_business_id,p_from_warehouse_id,p_to_warehouse_id,p_transfer_date,
   nullif(btrim(coalesce(p_note,'')),''),v_canonical_items)::text);
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text||':transfer:'||p_idempotency_key,0));
 select st.id,md5(jsonb_build_array(st.business_id,st.from_warehouse_id,st.to_warehouse_id,st.transfer_date,
   nullif(btrim(coalesce(st.note,'')),''),coalesce((select jsonb_agg(
     jsonb_build_object('product_id',si.product_id,'quantity',si.quantity) order by si.line_order
   ) from public.stock_transfer_items si where si.business_id=st.business_id and si.transfer_id=st.id),'[]'::jsonb)))
 into v_existing_id,v_existing_fingerprint
 from public.stock_transfers st
 where st.business_id=p_business_id and st.idempotency_key=p_idempotency_key;
 if v_existing_id is not null then
  if v_existing_fingerprint is distinct from v_fingerprint then
   raise exception using errcode='23505',message='Idempotency key reused with different transfer data';
  end if;
  return v_existing_id;
 end if;

 for v_product_id in
  select (e.value->>'product_id')::uuid
  from jsonb_array_elements(p_items) e
  order by (e.value->>'product_id')::uuid
 loop
  perform 1 from public.products p
  where p.business_id=p_business_id and p.id=v_product_id and p.is_active and p.track_inventory
  for update;
  if not found then
   raise exception using errcode='22023',message='Transfer product is missing, inactive or does not track inventory';
  end if;
 end loop;

 for v_item in select value from jsonb_array_elements(p_items) loop
  v_product_id:=nullif(v_item->>'product_id','')::uuid;
  v_qty:=(v_item->>'quantity')::numeric;
  select coalesce(sum(sm.quantity_delta),0) into v_stock_available
  from public.stock_movements sm
  where sm.business_id=p_business_id and sm.product_id=v_product_id and sm.warehouse_id=p_from_warehouse_id;
  select coalesce(sum(l.quantity_remaining),0) into v_layer_available
  from public.inventory_cost_layers l
  where l.business_id=p_business_id and l.product_id=v_product_id
    and l.warehouse_id=p_from_warehouse_id and l.quantity_remaining>0;
  if v_stock_available<v_qty or v_layer_available<v_qty then
   raise exception using errcode='23514',message='Insufficient reconciled stock or FIFO cost layers in source warehouse';
  end if;
 end loop;

 insert into public.stock_transfers(
   business_id,from_warehouse_id,to_warehouse_id,transfer_date,status,note,idempotency_key,created_by
 ) values (
   p_business_id,p_from_warehouse_id,p_to_warehouse_id,p_transfer_date,'draft',
   nullif(btrim(coalesce(p_note,'')),''),p_idempotency_key,v_user
 ) returning id into v_transfer_id;

 for v_item in select value from jsonb_array_elements(p_items) loop
  v_line:=v_line+1;
  v_product_id:=(v_item->>'product_id')::uuid;
  v_qty:=(v_item->>'quantity')::numeric(20,4);

  insert into public.stock_transfer_items(business_id,transfer_id,product_id,quantity,line_order)
  values(p_business_id,v_transfer_id,v_product_id,v_qty,v_line);

  insert into public.stock_movements(
    business_id,product_id,warehouse_id,movement_type,quantity_delta,movement_date,
    transfer_id,idempotency_key,note,created_by
  ) values (
    p_business_id,v_product_id,p_from_warehouse_id,'transfer_out',-v_qty,
    p_transfer_date::timestamptz,v_transfer_id,v_transfer_id::text||':'||v_line||':out',
    nullif(btrim(coalesce(p_note,'')),''),v_user
  ) returning id into v_from_movement_id;

  insert into public.stock_movements(
    business_id,product_id,warehouse_id,movement_type,quantity_delta,movement_date,
    transfer_id,idempotency_key,note,created_by
  ) values (
    p_business_id,v_product_id,p_to_warehouse_id,'transfer_in',v_qty,
    p_transfer_date::timestamptz,v_transfer_id,v_transfer_id::text||':'||v_line||':in',
    nullif(btrim(coalesce(p_note,'')),''),v_user
  ) returning id into v_to_movement_id;

  v_remaining:=v_qty;
  v_cost_total:=0;
  for v_layer in
    select l.id,l.quantity_remaining,l.unit_cost,l.acquired_at
    from public.inventory_cost_layers l
    where l.business_id=p_business_id and l.product_id=v_product_id
      and l.warehouse_id=p_from_warehouse_id and l.quantity_remaining>0
    order by l.acquired_at,l.id
    for update
  loop
    exit when v_remaining<=0;
    v_take:=least(v_remaining,v_layer.quantity_remaining);
    v_cost_total:=v_cost_total+round(v_take*v_layer.unit_cost);

    update public.inventory_cost_layers
    set quantity_remaining=quantity_remaining-v_take
    where business_id=p_business_id and id=v_layer.id;

    insert into public.inventory_cost_allocations(
      business_id,layer_id,stock_movement_id,quantity,unit_cost,total_cost
    ) values (
      p_business_id,v_layer.id,v_from_movement_id,v_take,v_layer.unit_cost,round(v_take*v_layer.unit_cost)
    );

    insert into public.inventory_cost_layers(
      business_id,product_id,warehouse_id,source_movement_id,
      quantity_in,quantity_remaining,unit_cost,acquired_at
    ) values (
      p_business_id,v_product_id,p_to_warehouse_id,v_to_movement_id,
      v_take,v_take,v_layer.unit_cost,v_layer.acquired_at
    );

    v_remaining:=v_remaining-v_take;
  end loop;

  if v_remaining>0 then
   raise exception using errcode='23514',message='FIFO layer balance changed during transfer';
  end if;
 end loop;

 update public.stock_transfers
 set status='posted',version=version+1,updated_at=now()
 where business_id=p_business_id and id=v_transfer_id;
 return v_transfer_id;
end;
$$;

revoke all on function public.post_stock_transfer(uuid,uuid,uuid,date,text,jsonb,text) from public,anon;
grant execute on function public.post_stock_transfer(uuid,uuid,uuid,date,text,jsonb,text) to authenticated;

commit;
