-- 020: goods-sale posting consumes FIFO layers and records balanced revenue/COGS.
begin;

do $test$
declare
  v_owner uuid:='94000000-0000-4000-8000-000000000001';
  v_outsider uuid:='94000000-0000-4000-8000-000000000002';
  v_business uuid:='95000000-0000-4000-8000-000000000001';
  v_other_business uuid:='95000000-0000-4000-8000-000000000002';
  v_supplier uuid;
  v_customer uuid;
  v_warehouse uuid;
  v_product uuid;
  v_purchase_doc uuid;
  v_purchase_item uuid;
  v_sale_doc uuid;
  v_sale_item uuid;
  v_purchase_journal uuid;
  v_sale_journal uuid;
  v_replay uuid;
  v_movement uuid;
  v_count integer;
  v_debit numeric;
  v_credit numeric;
  v_failed boolean:=false;
begin
  insert into auth.users(id,email,email_confirmed_at)
  values(v_owner,'sale-owner@example.test',now()),(v_outsider,'sale-outsider@example.test',now())
  on conflict(id) do nothing;
  insert into public.businesses(id,name,owner_user_id)
  values(v_business,'Sale business',v_owner),(v_other_business,'Other sale business',v_outsider)
  on conflict(id) do nothing;
  insert into public.business_members(business_id,user_id,role_code,status,joined_at)
  values(v_business,v_owner,'owner','active',now()),(v_other_business,v_outsider,'owner','active',now())
  on conflict(business_id,user_id) do nothing;

  insert into public.contacts(business_id,contact_type,name,legacy_id)
  values(v_business,'supplier','Sale supplier','sale-supplier')
  returning id into v_supplier;
  insert into public.contacts(business_id,contact_type,name,legacy_id)
  values(v_business,'customer','Sale customer','sale-customer')
  returning id into v_customer;
  insert into public.warehouses(business_id,name,code,is_default)
  values(v_business,'Sale warehouse','SALE',true)
  returning id into v_warehouse;
  insert into public.products(business_id,name,sale_price,track_inventory,legacy_id)
  values(v_business,'Sale product',1500,true,'sale-product')
  returning id into v_product;

  insert into public.documents(
    business_id,document_type,contact_id,warehouse_id,document_date,status,
    subtotal,discount_amount,taxable_amount,tax_amount,total_amount,notes
  ) values (
    v_business,'purchase',v_supplier,v_warehouse,current_date,'draft',
    2000,0,2000,200,2200,'Purchase for sale test'
  ) returning id into v_purchase_doc;
  insert into public.document_items(
    business_id,document_id,item_type,product_id,description_snapshot,quantity,
    unit_name_snapshot,unit_price,discount_amount,tax_rate_snapshot,tax_amount,line_total,sort_order
  ) values (
    v_business,v_purchase_doc,'goods',v_product,'Sale product',2,'عدد',1000,0,10,200,2200,1
  ) returning id into v_purchase_item;

  insert into public.documents(
    business_id,document_type,contact_id,warehouse_id,document_date,status,
    subtotal,discount_amount,taxable_amount,tax_amount,total_amount,notes
  ) values (
    v_business,'goods_sale',v_customer,v_warehouse,current_date,'draft',
    1500,0,1500,150,1650,'Test goods sale'
  ) returning id into v_sale_doc;
  insert into public.document_items(
    business_id,document_id,item_type,product_id,description_snapshot,quantity,
    unit_name_snapshot,unit_price,discount_amount,tax_rate_snapshot,tax_amount,line_total,sort_order
  ) values (
    v_business,v_sale_doc,'goods',v_product,'Sale product',1,'عدد',1500,0,10,150,1650,1
  ) returning id into v_sale_item;

  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  v_purchase_journal:=public.post_purchase_document(v_business,v_purchase_doc,'sale-test-purchase-key');
  v_sale_journal:=public.post_goods_sale_document(v_business,v_sale_doc,'sale-test-key-001');
  v_replay:=public.post_goods_sale_document(v_business,v_sale_doc,'sale-test-key-001');
  if v_sale_journal<>v_replay then raise exception 'Goods-sale replay must return the original journal'; end if;

  if (select status from public.documents where business_id=v_business and id=v_sale_doc)<>'posted' then
    raise exception 'Goods-sale document must be posted';
  end if;
  if (select count(*) from public.stock_movements
      where business_id=v_business and document_id=v_sale_doc and movement_type='sale')<>1 then
    raise exception 'Goods sale must create one stock movement per document line';
  end if;
  select id into v_movement from public.stock_movements
  where business_id=v_business and document_id=v_sale_doc;
  if (select quantity_delta from public.stock_movements
      where business_id=v_business and id=v_movement)<>-1 then
    raise exception 'Goods sale stock movement must reduce quantity';
  end if;
  if (select quantity_remaining from public.inventory_cost_layers
      where business_id=v_business and product_id=v_product and warehouse_id=v_warehouse)<>1 then
    raise exception 'FIFO layer remaining quantity mismatch';
  end if;
  if (select sum(total_cost) from public.inventory_cost_allocations
      where business_id=v_business and stock_movement_id=v_movement)<>1000 then
    raise exception 'FIFO allocation cost mismatch';
  end if;
  if (select total_cost_snapshot from public.document_item_costs
      where business_id=v_business and document_item_id=v_sale_item)<>1000 then
    raise exception 'Goods-sale cost snapshot mismatch';
  end if;
  if (select debit from public.contact_ledger_entries
      where business_id=v_business and document_id=v_sale_doc and entry_type='invoice_debit')<>1650 then
    raise exception 'Customer ledger must reflect full goods-sale amount';
  end if;

  select count(*),sum(debit),sum(credit) into v_count,v_debit,v_credit
  from public.journal_lines where business_id=v_business and journal_entry_id=v_sale_journal;
  if v_count<>5 or v_debit<>2650 or v_credit<>2650 then
    raise exception 'Goods-sale journal must balance receivable, tax, revenue and FIFO COGS';
  end if;
  if (select status from public.journal_entries where business_id=v_business and id=v_sale_journal)<>'posted' then
    raise exception 'Goods-sale journal must be posted';
  end if;

  v_failed:=false;
  begin
    perform public.post_goods_sale_document(v_business,v_sale_doc,'sale-test-other-key');
  exception when object_not_in_prerequisite_state then
    v_failed:=true;
  end;
  if not v_failed then raise exception 'Posted goods sale must not be posted again with another key'; end if;

  v_failed:=false;
  perform set_config('request.jwt.claim.sub',v_outsider::text,true);
  begin
    perform public.post_goods_sale_document(v_business,v_sale_doc,'outsider-sale-key');
  exception when insufficient_privilege then
    v_failed:=true;
  end;
  if not v_failed then raise exception 'Cross-business goods-sale posting must be denied'; end if;
end;
$test$;

rollback;
