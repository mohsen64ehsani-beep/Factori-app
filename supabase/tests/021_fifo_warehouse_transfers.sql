-- 021: warehouse transfers preserve FIFO costs and remain saleable in the destination.
begin;

do $test$
declare
  v_owner uuid:='96000000-0000-4000-8000-000000000001';
  v_outsider uuid:='96000000-0000-4000-8000-000000000002';
  v_business uuid:='97000000-0000-4000-8000-000000000001';
  v_other_business uuid:='97000000-0000-4000-8000-000000000002';
  v_supplier uuid;
  v_customer uuid;
  v_from uuid;
  v_to uuid;
  v_product uuid;
  v_purchase_doc uuid;
  v_transfer uuid;
  v_transfer_replay uuid;
  v_sale_doc uuid;
  v_sale_journal uuid;
  v_from_layer_remaining numeric;
  v_to_layer_quantity numeric;
  v_to_layer_cost numeric;
  v_transfer_out uuid;
  v_failed boolean:=false;
begin
  insert into auth.users(id,email,email_confirmed_at)
  values(v_owner,'transfer-owner@example.test',now()),(v_outsider,'transfer-outsider@example.test',now())
  on conflict(id) do nothing;
  insert into public.businesses(id,name,owner_user_id)
  values(v_business,'Transfer business',v_owner),(v_other_business,'Other transfer business',v_outsider)
  on conflict(id) do nothing;
  insert into public.business_members(business_id,user_id,role_code,status,joined_at)
  values(v_business,v_owner,'owner','active',now()),(v_other_business,v_outsider,'owner','active',now())
  on conflict(business_id,user_id) do nothing;

  insert into public.contacts(business_id,contact_type,name,legacy_id)
  values(v_business,'supplier','Transfer supplier','transfer-supplier')
  returning id into v_supplier;
  insert into public.contacts(business_id,contact_type,name,legacy_id)
  values(v_business,'customer','Transfer customer','transfer-customer')
  returning id into v_customer;
  insert into public.warehouses(business_id,name,code,is_default)
  values(v_business,'Transfer source','SRC',true)
  returning id into v_from;
  insert into public.warehouses(business_id,name,code,is_default)
  values(v_business,'Transfer destination','DST',false)
  returning id into v_to;
  insert into public.products(business_id,name,sale_price,track_inventory,legacy_id)
  values(v_business,'Transfer product',1500,true,'transfer-product')
  returning id into v_product;

  insert into public.documents(
    business_id,document_type,contact_id,warehouse_id,document_date,status,
    subtotal,discount_amount,taxable_amount,tax_amount,total_amount
  ) values (
    v_business,'purchase',v_supplier,v_from,current_date,'draft',2000,0,2000,0,2000
  ) returning id into v_purchase_doc;
  insert into public.document_items(
    business_id,document_id,item_type,product_id,description_snapshot,quantity,
    unit_name_snapshot,unit_price,discount_amount,tax_rate_snapshot,tax_amount,line_total,sort_order
  ) values (
    v_business,v_purchase_doc,'goods',v_product,'Transfer product',2,'عدد',1000,0,0,0,2000,1
  );

  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  perform public.post_purchase_document(v_business,v_purchase_doc,'transfer-purchase-key');
  v_transfer:=public.post_stock_transfer(
    v_business,v_from,v_to,current_date,'FIFO transfer',
    jsonb_build_array(jsonb_build_object('product_id',v_product,'quantity',1)),
    'transfer-key-001'
  );
  v_transfer_replay:=public.post_stock_transfer(
    v_business,v_from,v_to,current_date,'FIFO transfer',
    jsonb_build_array(jsonb_build_object('product_id',v_product,'quantity',1)),
    'transfer-key-001'
  );
  if v_transfer<>v_transfer_replay then raise exception 'Transfer replay must return the original transfer'; end if;

  select quantity_remaining into v_from_layer_remaining
  from public.inventory_cost_layers
  where business_id=v_business and product_id=v_product and warehouse_id=v_from;
  select quantity_in,unit_cost into v_to_layer_quantity,v_to_layer_cost
  from public.inventory_cost_layers
  where business_id=v_business and product_id=v_product and warehouse_id=v_to;
  if v_from_layer_remaining<>1 or v_to_layer_quantity<>1 or v_to_layer_cost<>1000 then
    raise exception 'FIFO layer quantity or cost was not preserved across warehouses';
  end if;

  select id into v_transfer_out from public.stock_movements
  where business_id=v_business and transfer_id=v_transfer and movement_type='transfer_out';
  if (select sum(total_cost) from public.inventory_cost_allocations
      where business_id=v_business and stock_movement_id=v_transfer_out)<>1000 then
    raise exception 'Transfer-out cost allocation mismatch';
  end if;

  insert into public.documents(
    business_id,document_type,contact_id,warehouse_id,document_date,status,
    subtotal,discount_amount,taxable_amount,tax_amount,total_amount
  ) values (
    v_business,'goods_sale',v_customer,v_to,current_date,'draft',1500,0,1500,0,1500
  ) returning id into v_sale_doc;
  insert into public.document_items(
    business_id,document_id,item_type,product_id,description_snapshot,quantity,
    unit_name_snapshot,unit_price,discount_amount,tax_rate_snapshot,tax_amount,line_total,sort_order
  ) values (
    v_business,v_sale_doc,'goods',v_product,'Transfer product',1,'عدد',1500,0,0,0,1500,1
  );
  v_sale_journal:=public.post_goods_sale_document(v_business,v_sale_doc,'transfer-sale-key');
  if not exists(
    select 1 from public.document_item_costs
    where business_id=v_business and document_item_id=(
      select id from public.document_items where business_id=v_business and document_id=v_sale_doc
    ) and total_cost_snapshot=1000
  ) then raise exception 'Destination FIFO layer could not be consumed at its original cost'; end if;

  v_failed:=false;
  perform set_config('request.jwt.claim.sub',v_outsider::text,true);
  begin
    perform public.post_stock_transfer(
      v_business,v_from,v_to,current_date,'unauthorized',
      jsonb_build_array(jsonb_build_object('product_id',v_product,'quantity',0.1)),
      'transfer-outsider-key'
    );
  exception when insufficient_privilege then
    v_failed:=true;
  end;
  if not v_failed then raise exception 'Cross-business stock transfer must be denied'; end if;
end;
$test$;

rollback;
