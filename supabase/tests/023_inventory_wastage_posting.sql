-- 023: Wastage consumes FIFO stock, records cost and balances expense against inventory.
begin;

do $test$
declare
 v_owner uuid:='9a000000-0000-4000-8000-000000000001';
 v_outsider uuid:='9a000000-0000-4000-8000-000000000002';
 v_business uuid:='9b000000-0000-4000-8000-000000000001';
 v_other_business uuid:='9b000000-0000-4000-8000-000000000002';
 v_supplier uuid;
 v_warehouse uuid;
 v_product uuid;
 v_purchase uuid;
 v_purchase_journal uuid;
 v_waste uuid;
 v_replay uuid;
 v_journal uuid;
 v_movement uuid;
 v_failed boolean:=false;
 v_count integer;
 v_debit numeric;
 v_credit numeric;
begin
 insert into auth.users(id,email,email_confirmed_at)
 values(v_owner,'waste-owner@example.test',now()),(v_outsider,'waste-outsider@example.test',now())
 on conflict(id) do nothing;
 insert into public.businesses(id,name,owner_user_id)
 values(v_business,'Wastage business',v_owner),(v_other_business,'Other wastage business',v_outsider)
 on conflict(id) do nothing;
 insert into public.business_members(business_id,user_id,role_code,status,joined_at)
 values(v_business,v_owner,'owner','active',now()),(v_other_business,v_outsider,'owner','active',now())
 on conflict(business_id,user_id) do nothing;
 insert into public.contacts(business_id,contact_type,name,legacy_id)
 values(v_business,'supplier','Wastage supplier','wastage-supplier') returning id into v_supplier;
 insert into public.warehouses(business_id,name,code,is_default)
 values(v_business,'Wastage warehouse','WST',true) returning id into v_warehouse;
 insert into public.products(business_id,name,sale_price,track_inventory,legacy_id)
 values(v_business,'Wastage product',1500,true,'wastage-product') returning id into v_product;
 insert into public.documents(
  business_id,document_type,contact_id,warehouse_id,document_date,status,
  subtotal,discount_amount,taxable_amount,tax_amount,total_amount
 ) values (
  v_business,'purchase',v_supplier,v_warehouse,current_date,'draft',3000,0,3000,0,3000
 ) returning id into v_purchase;
 insert into public.document_items(
  business_id,document_id,item_type,product_id,description_snapshot,quantity,
  unit_name_snapshot,unit_price,discount_amount,tax_rate_snapshot,tax_amount,line_total,sort_order
 ) values (
  v_business,v_purchase,'goods',v_product,'Wastage product',3,'عدد',1000,0,0,0,3000,1
 );
 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_purchase_journal:=public.post_purchase_document(v_business,v_purchase,'waste-purchase-key');

 v_waste:=public.post_inventory_wastage(
  v_business,current_date,'Damaged goods',
  jsonb_build_array(jsonb_build_object('product_id',v_product,'warehouse_id',v_warehouse,'quantity',1)),
  'wastage-key-001'
 );
 v_replay:=public.post_inventory_wastage(
  v_business,current_date,'Damaged goods',
  jsonb_build_array(jsonb_build_object('product_id',v_product,'warehouse_id',v_warehouse,'quantity',1)),
  'wastage-key-001'
 );
 if v_waste<>v_replay then raise exception 'Wastage retry must return the original batch'; end if;
 select stock_movement_id into v_movement from public.inventory_wastage_items
 where business_id=v_business and batch_id=v_waste;
 if (select quantity_delta from public.stock_movements
  where business_id=v_business and id=v_movement)<>-1 then
  raise exception 'Wastage stock movement quantity mismatch';
 end if;
 if (select sum(quantity_remaining) from public.inventory_cost_layers
  where business_id=v_business and product_id=v_product and warehouse_id=v_warehouse)<>2 then
  raise exception 'Wastage FIFO layer quantity mismatch';
 end if;
 if (select total_cost from public.inventory_wastage_batches
  where business_id=v_business and id=v_waste)<>1000 then
  raise exception 'Wastage FIFO cost mismatch';
 end if;
 select journal_entry_id into v_journal from public.inventory_wastage_batches
 where business_id=v_business and id=v_waste;
 select count(*),sum(debit),sum(credit) into v_count,v_debit,v_credit
 from public.journal_lines where business_id=v_business and journal_entry_id=v_journal;
 if v_count<>2 or v_debit<>1000 or v_credit<>1000 then
  raise exception 'Wastage journal must balance expense and inventory';
 end if;
 v_failed:=false;
 begin
  perform public.post_inventory_wastage(
   v_business,current_date,'Too much',
   jsonb_build_array(jsonb_build_object('product_id',v_product,'warehouse_id',v_warehouse,'quantity',99)),
   'wastage-key-insufficient'
  );
 exception when check_violation then v_failed:=true;
 end;
 if not v_failed then raise exception 'Wastage beyond available FIFO stock must fail'; end if;
 v_failed:=false;
 perform set_config('request.jwt.claim.sub',v_outsider::text,true);
 begin
  perform public.post_inventory_wastage(
   v_business,current_date,'Unauthorized',
   jsonb_build_array(jsonb_build_object('product_id',v_product,'warehouse_id',v_warehouse,'quantity',0.5)),
   'wastage-outsider'
  );
 exception when insufficient_privilege then v_failed:=true;
 end;
 if not v_failed then raise exception 'Cross-business wastage must be denied'; end if;
end;
$test$;

rollback;
