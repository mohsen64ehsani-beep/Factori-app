-- 036: Purchase returns consume only the original FIFO layer; supplier refunds are capped by return value and supplier debit.
begin;
do $test$
declare
 v_owner uuid:='d1000000-0000-4000-8000-000000000001';
 v_outsider uuid:='d1000000-0000-4000-8000-000000000002';
 v_business uuid:='d2000000-0000-4000-8000-000000000001';
 v_other_business uuid:='d2000000-0000-4000-8000-000000000002';
 v_supplier uuid; v_warehouse uuid; v_product uuid; v_account uuid; v_purchase_doc uuid; v_purchase_item uuid;
 v_return_id uuid; v_return_replay uuid; v_refund_tx uuid; v_refund_replay uuid; v_layer_id uuid;
 v_journal_id uuid; v_count integer; v_debit numeric; v_credit numeric; v_failed boolean:=false;
begin
 insert into auth.users(id,email,email_confirmed_at)
 values(v_owner,'purchase-return-owner@example.test',now()),(v_outsider,'purchase-return-outsider@example.test',now())
 on conflict(id) do nothing;
 insert into public.businesses(id,name,owner_user_id)
 values(v_business,'Purchase return business',v_owner),(v_other_business,'Other purchase return business',v_outsider)
 on conflict(id) do nothing;
 insert into public.business_members(business_id,user_id,role_code,status,joined_at)
 values(v_business,v_owner,'owner','active',now()),(v_other_business,v_outsider,'owner','active',now())
 on conflict(business_id,user_id) do nothing;
 insert into public.contacts(business_id,contact_type,name,legacy_id)
 values(v_business,'supplier','Return supplier','return-supplier') returning id into v_supplier;
 insert into public.warehouses(business_id,name,code,is_default,is_active)
 values(v_business,'Return warehouse','RET',true,true) returning id into v_warehouse;
 insert into public.products(business_id,name,unit_name,track_inventory,is_active,legacy_id)
 values(v_business,'Return product','عدد',true,true,'return-product') returning id into v_product;
 select id into v_account from public.financial_accounts where business_id=v_business and is_default and is_active;
 if v_account is null then raise exception 'Default financial account was not initialized'; end if;

 insert into public.documents(business_id,document_type,contact_id,warehouse_id,document_date,status,
  subtotal,discount_amount,taxable_amount,tax_amount,total_amount,notes)
 values(v_business,'purchase',v_supplier,v_warehouse,current_date,'draft',1000,0,1000,100,1100,'Purchase return test')
 returning id into v_purchase_doc;
 insert into public.document_items(business_id,document_id,item_type,product_id,description_snapshot,quantity,
  unit_name_snapshot,unit_price,discount_amount,tax_rate_snapshot,tax_amount,line_total,sort_order)
 values(v_business,v_purchase_doc,'goods',v_product,'Return product',10,'عدد',100,0,10,100,1100,1)
 returning id into v_purchase_item;

 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 perform public.post_purchase_document(v_business,v_purchase_doc,'purchase-return-base-001');
 v_return_id:=public.post_purchase_return(v_business,v_purchase_doc,current_date,
  jsonb_build_array(jsonb_build_object('document_item_id',v_purchase_item,'quantity',4)),
  'Damaged goods returned','purchase-return-key-001');
 v_return_replay:=public.post_purchase_return(v_business,v_purchase_doc,current_date,
  jsonb_build_array(jsonb_build_object('document_item_id',v_purchase_item,'quantity',4)),
  'Damaged goods returned','purchase-return-key-001');
 if v_return_id<>v_return_replay then raise exception 'Purchase return retry must return the original return'; end if;
 if (select status from public.purchase_return_documents where business_id=v_business and id=v_return_id)<>'posted'
  or (select total_amount from public.purchase_return_documents where business_id=v_business and id=v_return_id)<>440 then
  raise exception 'Purchase return document status or amount is incorrect';
 end if;
 select l.id into v_layer_id from public.inventory_cost_layers l
 join public.stock_movements sm on sm.business_id=l.business_id and sm.id=l.source_movement_id
 where l.business_id=v_business and sm.document_id=v_purchase_doc and sm.document_item_id=v_purchase_item and sm.movement_type='purchase';
 if (select quantity_remaining from public.inventory_cost_layers where business_id=v_business and id=v_layer_id)<>6 then
  raise exception 'Purchase return must reduce only the original FIFO layer';
 end if;
 if not exists(select 1 from public.inventory_cost_allocations ica
  join public.stock_movements sm on sm.business_id=ica.business_id and sm.id=ica.stock_movement_id
  where ica.business_id=v_business and ica.layer_id=v_layer_id and sm.movement_type='purchase_return'
   and ica.quantity=4 and ica.total_cost=400) then
  raise exception 'Purchase return FIFO cost allocation is missing';
 end if;
 if not exists(select 1 from public.contact_ledger_entries cle
  where cle.business_id=v_business and cle.document_id=v_purchase_doc
   and cle.entry_type='purchase_return' and cle.debit=440 and cle.credit=0) then
  raise exception 'Supplier ledger must record purchase return debit';
 end if;
 select je.id into v_journal_id from public.journal_entries je
 where je.business_id=v_business and je.source_type='document' and je.source_id=v_return_id;
 select count(*),sum(debit),sum(credit) into v_count,v_debit,v_credit
 from public.journal_lines where business_id=v_business and journal_entry_id=v_journal_id;
 if v_count<>3 or v_debit<>440 or v_credit<>440 then raise exception 'Purchase return journal must balance'; end if;

 v_failed:=false;
 begin
  perform public.post_purchase_return(v_business,v_purchase_doc,current_date,
   jsonb_build_array(jsonb_build_object('document_item_id',v_purchase_item,'quantity',7)),
   'Over return','purchase-return-over-001');
 exception when check_violation then v_failed:=true;
 end;
 if not v_failed then raise exception 'Purchase return must not exceed remaining original FIFO quantity'; end if;

 v_failed:=false;
 begin
  perform public.post_supplier_refund(v_business,v_return_id,v_account,100,current_date,'SUP-REF-1',
   'premature supplier refund','supplier-refund-before-payment-001');
 exception when check_violation then v_failed:=true;
 end;
 if not v_failed then raise exception 'Supplier refund must be blocked while supplier still has a net payable balance'; end if;

 perform public.post_simple_financial_transaction(v_business,'supplier_payment',v_supplier,v_account,1100,current_date,
  'SUP-PAY-1','Settle original purchase','supplier-payment-return-001');
 v_refund_tx:=public.post_supplier_refund(v_business,v_return_id,v_account,200,current_date,'SUP-REF-1',
  'Partial supplier refund','supplier-refund-key-001');
 v_refund_replay:=public.post_supplier_refund(v_business,v_return_id,v_account,200,current_date,'SUP-REF-1',
  'Partial supplier refund','supplier-refund-key-001');
 if v_refund_tx<>v_refund_replay then raise exception 'Supplier refund retry must return original transaction'; end if;
 if (select refunded_amount from public.purchase_return_documents where business_id=v_business and id=v_return_id)<>200 then
  raise exception 'Supplier refund allocation must update the return document';
 end if;
 if not exists(select 1 from public.financial_transactions where business_id=v_business and id=v_refund_tx
  and transaction_type='supplier_refund' and direction='in' and amount=200) then
  raise exception 'Supplier refund financial transaction missing';
 end if;
 if not exists(select 1 from public.contact_ledger_entries where business_id=v_business and transaction_id=v_refund_tx
  and entry_type='adjustment_credit' and debit=0 and credit=200) then
  raise exception 'Supplier refund must reduce supplier debit balance';
 end if;
 select je.id into v_journal_id from public.journal_entries je
 where je.business_id=v_business and je.source_type='financial_transaction' and je.source_id=v_refund_tx;
 select count(*),sum(debit),sum(credit) into v_count,v_debit,v_credit
 from public.journal_lines where business_id=v_business and journal_entry_id=v_journal_id;
 if v_count<>2 or v_debit<>200 or v_credit<>200 then raise exception 'Supplier refund journal must balance'; end if;

 v_failed:=false;
 begin
  perform public.post_supplier_refund(v_business,v_return_id,v_account,241,current_date,'SUP-REF-2',
   'Refund above remaining supplier credit','supplier-refund-over-001');
 exception when check_violation then v_failed:=true;
 end;
 if not v_failed then raise exception 'Supplier refund must not exceed remaining return value or supplier debit balance'; end if;

 v_failed:=false;
 perform set_config('request.jwt.claim.sub',v_outsider::text,true);
 begin
  perform public.post_purchase_return(v_business,v_purchase_doc,current_date,
   jsonb_build_array(jsonb_build_object('document_item_id',v_purchase_item,'quantity',1)),
   'Cross-business return','purchase-return-outsider-001');
 exception when insufficient_privilege then v_failed:=true;
 end;
 if not v_failed then raise exception 'Cross-business purchase return must be denied'; end if;
end;
$test$;
rollback;
