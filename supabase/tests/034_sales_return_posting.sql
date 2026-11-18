-- 034: Sales returns must match original posted invoice lines and restore their exact FIFO costs.
begin;

do $test$
declare
 v_owner uuid:='e1000000-0000-4000-8000-000000000001';
 v_outsider uuid:='e1000000-0000-4000-8000-000000000002';
 v_business uuid:='e2000000-0000-4000-8000-000000000001';
 v_other_business uuid:='e2000000-0000-4000-8000-000000000002';
 v_customer uuid;
 v_supplier uuid;
 v_warehouse uuid;
 v_product uuid;
 v_purchase_doc uuid;
 v_purchase_item uuid;
 v_sale_doc uuid;
 v_sale_item uuid;
 v_return_id uuid;
 v_replay uuid;
 v_journal_id uuid;
 v_count integer;
 v_debit numeric;
 v_credit numeric;
 v_failed boolean:=false;
begin
 insert into auth.users(id,email,email_confirmed_at)
 values(v_owner,'sales-return-owner@example.test',now()),(v_outsider,'sales-return-outsider@example.test',now())
 on conflict(id) do nothing;
 insert into public.businesses(id,name,owner_user_id)
 values(v_business,'Sales return business',v_owner),(v_other_business,'Other return business',v_outsider)
 on conflict(id) do nothing;
 insert into public.business_members(business_id,user_id,role_code,status,joined_at)
 values(v_business,v_owner,'owner','active',now()),(v_other_business,v_outsider,'owner','active',now())
 on conflict(business_id,user_id) do nothing;
 insert into public.contacts(business_id,contact_type,name,legacy_id)
 values(v_business,'customer','Return customer','return-customer')
 returning id into v_customer;
 insert into public.contacts(business_id,contact_type,name,legacy_id)
 values(v_business,'supplier','Return supplier','return-supplier')
 returning id into v_supplier;
 insert into public.warehouses(business_id,name,is_default,is_active,legacy_id)
 values(v_business,'Main warehouse',true,true,'return-main-warehouse')
 returning id into v_warehouse;
 insert into public.products(business_id,name,unit_name,track_inventory,is_active,legacy_id)
 values(v_business,'Return product','عدد',true,true,'return-product')
 returning id into v_product;

 insert into public.documents(
  business_id,document_type,contact_id,warehouse_id,document_date,status,
  subtotal,discount_amount,taxable_amount,tax_amount,total_amount,notes
 ) values(
  v_business,'purchase',v_supplier,current_date,current_date,'draft',
  400,0,400,0,400,'Purchase for return test'
 ) returning id into v_purchase_doc;
 insert into public.document_items(
  business_id,document_id,item_type,product_id,description_snapshot,quantity,unit_name_snapshot,
  unit_price,discount_amount,tax_rate_snapshot,tax_amount,line_total,sort_order
 ) values(
  v_business,v_purchase_doc,'goods',v_product,'Return product',8,'عدد',50,0,0,0,400,1
 ) returning id into v_purchase_item;
 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 perform public.post_purchase_document(v_business,v_purchase_doc,'return-purchase-key-01');

 insert into public.documents(
  business_id,document_type,contact_id,warehouse_id,document_date,status,
  subtotal,discount_amount,taxable_amount,tax_amount,total_amount,notes
 ) values(
  v_business,'goods_sale',v_customer,v_warehouse,current_date,'draft',
  400,0,400,40,440,'Sale for return test'
 ) returning id into v_sale_doc;
 insert into public.document_items(
  business_id,document_id,item_type,product_id,description_snapshot,quantity,unit_name_snapshot,
  unit_price,discount_amount,tax_rate_snapshot,tax_amount,line_total,sort_order
 ) values(
  v_business,v_sale_doc,'goods',v_product,'Return product',4,'عدد',100,0,10,40,440,1
 ) returning id into v_sale_item;
 perform public.post_goods_sale_document(v_business,v_sale_doc,'return-sale-key-001');

 v_return_id:=public.post_sales_return(
  v_business,v_sale_doc,current_date,
  jsonb_build_array(jsonb_build_object('document_item_id',v_sale_item,'quantity',1)),
  'Customer returned one unit','sales-return-key-001'
 );
 v_replay:=public.post_sales_return(
  v_business,v_sale_doc,current_date,
  jsonb_build_array(jsonb_build_object('document_item_id',v_sale_item,'quantity',1)),
  'Customer returned one unit','sales-return-key-001'
 );
 if v_return_id<>v_replay then raise exception 'Sales return retry must return original return'; end if;
 if not exists(select 1 from public.sales_return_documents where business_id=v_business and id=v_return_id
  and status='posted' and taxable_amount=100 and tax_amount=10 and total_amount=110) then
  raise exception 'Sales return amounts or status are incorrect';
 end if;
 if (select sum(quantity_delta) from public.stock_movements
  where business_id=v_business and product_id=v_product and warehouse_id=v_warehouse)<>5 then
  raise exception 'Purchase, sale and first return stock balance should be five units';
 end if;
 if not exists(select 1 from public.inventory_cost_layers
  where business_id=v_business and product_id=v_product and warehouse_id=v_warehouse
   and source_movement_id=(select stock_movement_id from public.sales_return_items
    where business_id=v_business and return_document_id=v_return_id)
   and quantity_in=1 and quantity_remaining=1 and unit_cost=50) then
  raise exception 'Returned FIFO cost layer must preserve the original unit cost';
 end if;
 if not exists(select 1 from public.contact_ledger_entries
  where business_id=v_business and document_id=v_sale_doc and entry_type='sales_return'
   and credit=110 and debit=0) then
  raise exception 'Customer ledger must receive a credit for the return';
 end if;
 select journal_entry_id into v_journal_id from public.sales_return_documents
 where business_id=v_business and id=v_return_id;
 select count(*),sum(debit),sum(credit) into v_count,v_debit,v_credit
 from public.journal_lines where business_id=v_business and journal_entry_id=v_journal_id;
 if v_count<>5 or v_debit<>160 or v_credit<>160 then
  raise exception 'Sales return journal must balance revenue/tax/receivable and inventory/COGS';
 end if;

 -- Return the remaining three units; the original sold quantity is now fully returned.
 perform public.post_sales_return(
  v_business,v_sale_doc,current_date,
  jsonb_build_array(jsonb_build_object('document_item_id',v_sale_item,'quantity',3)),
  'Customer returned remaining units','sales-return-key-002'
 );
 v_failed:=false;
 begin
  perform public.post_sales_return(
   v_business,v_sale_doc,current_date,
   jsonb_build_array(jsonb_build_object('document_item_id',v_sale_item,'quantity',0.1)),
   'Over-return','sales-return-over-001'
  );
 exception when check_violation then v_failed:=true;
 end;
 if not v_failed then raise exception 'Returning more than the original invoice quantity must fail'; end if;

 v_failed:=false;
 perform set_config('request.jwt.claim.sub',v_outsider::text,true);
 begin
  perform public.post_sales_return(
   v_business,v_sale_doc,current_date,
   jsonb_build_array(jsonb_build_object('document_item_id',v_sale_item,'quantity',1)),
   'Outsider return','sales-return-outsider-01'
  );
 exception when insufficient_privilege then v_failed:=true;
 end;
 if not v_failed then raise exception 'Cross-business sales return must be denied'; end if;
end;
$test$;

rollback;
