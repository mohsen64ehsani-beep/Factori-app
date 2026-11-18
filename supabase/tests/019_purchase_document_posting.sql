-- 019: purchase posting creates inventory layers, supplier balance and balanced journal.
begin;

do $test$
declare
  v_owner uuid:='92000000-0000-4000-8000-000000000001';
  v_outsider uuid:='92000000-0000-4000-8000-000000000002';
  v_business uuid:='93000000-0000-4000-8000-000000000001';
  v_other_business uuid:='93000000-0000-4000-8000-000000000002';
  v_supplier uuid;
  v_warehouse uuid;
  v_product uuid;
  v_document uuid;
  v_item uuid;
  v_journal uuid;
  v_replay uuid;
  v_movement uuid;
  v_count integer;
  v_debit numeric;
  v_credit numeric;
  v_failed boolean:=false;
begin
  insert into auth.users(id,email,email_confirmed_at)
  values(v_owner,'purchase-owner@example.test',now()),(v_outsider,'purchase-outsider@example.test',now())
  on conflict(id) do nothing;
  insert into public.businesses(id,name,owner_user_id)
  values(v_business,'Purchase business',v_owner),(v_other_business,'Other purchase business',v_outsider)
  on conflict(id) do nothing;
  insert into public.business_members(business_id,user_id,role_code,status,joined_at)
  values(v_business,v_owner,'owner','active',now()),(v_other_business,v_outsider,'owner','active',now())
  on conflict(business_id,user_id) do nothing;

  insert into public.contacts(business_id,contact_type,name,legacy_id)
  values(v_business,'supplier','Purchase supplier','purchase-supplier')
  returning id into v_supplier;
  insert into public.warehouses(business_id,name,code,is_default)
  values(v_business,'Main warehouse','MAIN',true)
  returning id into v_warehouse;
  insert into public.products(business_id,name,sale_price,track_inventory,legacy_id)
  values(v_business,'Purchase product',1500,true,'purchase-product')
  returning id into v_product;

  insert into public.documents(
    business_id,document_type,contact_id,warehouse_id,document_date,status,
    subtotal,discount_amount,taxable_amount,tax_amount,total_amount,notes
  ) values (
    v_business,'purchase',v_supplier,v_warehouse,current_date,'draft',
    2000,0,2000,200,2200,'Test purchase'
  ) returning id into v_document;

  insert into public.document_items(
    business_id,document_id,item_type,product_id,description_snapshot,quantity,
    unit_name_snapshot,unit_price,discount_amount,tax_rate_snapshot,tax_amount,line_total,sort_order
  ) values (
    v_business,v_document,'goods',v_product,'Purchase product',2,'عدد',1000,0,10,200,2200,1
  ) returning id into v_item;

  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  v_journal:=public.post_purchase_document(v_business,v_document,'purchase-key-001');
  v_replay:=public.post_purchase_document(v_business,v_document,'purchase-key-001');
  if v_journal<>v_replay then raise exception 'Purchase replay must return the original journal'; end if;

  if (select status from public.documents where business_id=v_business and id=v_document)<>'posted' then
    raise exception 'Purchase document must be posted';
  end if;
  if (select count(*) from public.stock_movements
      where business_id=v_business and document_id=v_document and movement_type='purchase')<>1 then
    raise exception 'Purchase must create one stock movement per document line';
  end if;
  select id into v_movement from public.stock_movements
  where business_id=v_business and document_id=v_document;
  if (select quantity_remaining from public.inventory_cost_layers
      where business_id=v_business and source_movement_id=v_movement)<>2 then
    raise exception 'Purchase FIFO layer quantity mismatch';
  end if;
  if (select unit_cost from public.inventory_cost_layers
      where business_id=v_business and source_movement_id=v_movement)<>1000 then
    raise exception 'Purchase FIFO layer unit cost mismatch';
  end if;
  if (select total_cost_snapshot from public.document_item_costs
      where business_id=v_business and document_item_id=v_item)<>2000 then
    raise exception 'Protected document item cost snapshot mismatch';
  end if;
  if (select purchase_cost from public.product_costs
      where business_id=v_business and product_id=v_product order by effective_from desc limit 1)<>1000 then
    raise exception 'Product purchase cost history mismatch';
  end if;
  if (select credit from public.contact_ledger_entries
      where business_id=v_business and document_id=v_document and entry_type='invoice_credit')<>2200 then
    raise exception 'Supplier ledger must reflect total purchase liability';
  end if;

  select count(*),sum(debit),sum(credit) into v_count,v_debit,v_credit
  from public.journal_lines where business_id=v_business and journal_entry_id=v_journal;
  if v_count<>3 or v_debit<>2200 or v_credit<>2200 then
    raise exception 'Purchase journal must balance inventory, tax and supplier payable';
  end if;
  if (select status from public.journal_entries where business_id=v_business and id=v_journal)<>'posted' then
    raise exception 'Purchase journal must be posted';
  end if;

  v_failed:=false;
  begin
    perform public.post_purchase_document(v_business,v_document,'purchase-key-other');
  exception when object_not_in_prerequisite_state then
    v_failed:=true;
  end;
  if not v_failed then raise exception 'A posted purchase must not be posted again with another key'; end if;

  v_failed:=false;
  perform set_config('request.jwt.claim.sub',v_outsider::text,true);
  begin
    perform public.post_purchase_document(v_business,v_document,'outsider-purchase-key');
  exception when insufficient_privilege then
    v_failed:=true;
  end;
  if not v_failed then raise exception 'Cross-business purchase posting must be denied'; end if;
end;
$test$;

rollback;
