-- 035: Cash refunds are capped by both posted return value and the customer's net credit.
begin;

do $test$
declare
 v_owner uuid:='f1000000-0000-4000-8000-000000000001';
 v_outsider uuid:='f1000000-0000-4000-8000-000000000002';
 v_business uuid:='f2000000-0000-4000-8000-000000000001';
 v_other_business uuid:='f2000000-0000-4000-8000-000000000002';
 v_customer uuid;
 v_supplier uuid;
 v_warehouse uuid;
 v_product uuid;
 v_account uuid;
 v_purchase_doc uuid;
 v_sale_doc uuid;
 v_sale_item uuid;
 v_return_id uuid;
 v_refund_tx uuid;
 v_replay uuid;
 v_journal_id uuid;
 v_count integer;
 v_debit numeric;
 v_credit numeric;
 v_failed boolean:=false;
begin
 insert into auth.users(id,email,email_confirmed_at)
 values(v_owner,'customer-refund-owner@example.test',now()),(v_outsider,'customer-refund-outsider@example.test',now())
 on conflict(id) do nothing;
 insert into public.businesses(id,name,owner_user_id)
 values(v_business,'Customer refund business',v_owner),(v_other_business,'Other customer refund business',v_outsider)
 on conflict(id) do nothing;
 insert into public.business_members(business_id,user_id,role_code,status,joined_at)
 values(v_business,v_owner,'owner','active',now()),(v_other_business,v_outsider,'owner','active',now())
 on conflict(business_id,user_id) do nothing;
 insert into public.contacts(business_id,contact_type,name,legacy_id)
 values(v_business,'customer','Refund customer','refund-customer')
 returning id into v_customer;
 insert into public.contacts(business_id,contact_type,name,legacy_id)
 values(v_business,'supplier','Refund supplier','refund-supplier')
 returning id into v_supplier;
 insert into public.warehouses(business_id,name,is_default,is_active)
 values(v_business,'Refund warehouse',true,true)
 returning id into v_warehouse;
 insert into public.products(business_id,name,unit_name,track_inventory,is_active,legacy_id)
 values(v_business,'Refund product','عدد',true,true,'refund-product')
 returning id into v_product;
 select id into v_account from public.financial_accounts
 where business_id=v_business and is_default and is_active;

 insert into public.documents(
  business_id,document_type,contact_id,warehouse_id,document_date,status,
  subtotal,discount_amount,taxable_amount,tax_amount,total_amount,notes
 ) values(
  v_business,'purchase',v_supplier,v_warehouse,current_date,'draft',
  400,0,400,0,400,'Refund test purchase'
 ) returning id into v_purchase_doc;
 insert into public.document_items(
  business_id,document_id,item_type,product_id,description_snapshot,quantity,unit_name_snapshot,
  unit_price,discount_amount,tax_rate_snapshot,tax_amount,line_total,sort_order
 ) values(
  v_business,v_purchase_doc,'goods',v_product,'Refund product',8,'عدد',50,0,0,0,400,1
 );
 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 perform public.post_purchase_document(v_business,v_purchase_doc,'refund-purchase-key-01');

 insert into public.documents(
  business_id,document_type,contact_id,warehouse_id,document_date,status,
  subtotal,discount_amount,taxable_amount,tax_amount,total_amount,notes
 ) values(
  v_business,'goods_sale',v_customer,v_warehouse,current_date,'draft',
  400,0,400,40,440,'Refund test sale'
 ) returning id into v_sale_doc;
 insert into public.document_items(
  business_id,document_id,item_type,product_id,description_snapshot,quantity,unit_name_snapshot,
  unit_price,discount_amount,tax_rate_snapshot,tax_amount,line_total,sort_order
 ) values(
  v_business,v_sale_doc,'goods',v_product,'Refund product',4,'عدد',100,0,10,40,440,1
 ) returning id into v_sale_item;
 perform public.post_goods_sale_document(v_business,v_sale_doc,'refund-sale-key-001');

 v_return_id:=public.post_sales_return(
  v_business,v_sale_doc,current_date,
  jsonb_build_array(jsonb_build_object('document_item_id',v_sale_item,'quantity',1)),
  'Refund test return','refund-sales-return-01'
 );

 v_failed:=false;
 begin
  perform public.post_customer_refund(v_business,v_return_id,v_account,50,current_date,'REF-1','premature refund','refund-before-payment-01');
 exception when check_violation then v_failed:=true;
 end;
 if not v_failed then raise exception 'Refund must be blocked while customer still owes the original invoice'; end if;

 perform public.post_customer_receipt(
  v_business,v_customer,v_account,440,current_date,v_sale_doc,440,
  'RCPT-REFUND','settled original sale','refund-receipt-key-001'
 );

 v_refund_tx:=public.post_customer_refund(
  v_business,v_return_id,v_account,50,current_date,'REF-1','partial cash refund','customer-refund-key-001'
 );
 v_replay:=public.post_customer_refund(
  v_business,v_return_id,v_account,50,current_date,'REF-1','partial cash refund','customer-refund-key-001'
 );
 if v_refund_tx<>v_replay then raise exception 'Customer refund retry must return original transaction'; end if;
 if (select refunded_amount from public.sales_return_documents
  where business_id=v_business and id=v_return_id)<>50 then
  raise exception 'Sales return refunded amount must update';
 end if;
 if not exists(select 1 from public.financial_transactions
  where business_id=v_business and id=v_refund_tx and transaction_type='customer_refund'
   and direction='out' and amount=50) then
  raise exception 'Customer refund financial transaction missing';
 end if;
 if not exists(select 1 from public.contact_ledger_entries
  where business_id=v_business and transaction_id=v_refund_tx
   and entry_type='adjustment_debit' and debit=50 and credit=0) then
  raise exception 'Customer refund must debit customer ledger';
 end if;
 select je.id into v_journal_id from public.journal_entries je
 where je.business_id=v_business and je.source_type='financial_transaction' and je.source_id=v_refund_tx;
 select count(*),sum(debit),sum(credit) into v_count,v_debit,v_credit
 from public.journal_lines where business_id=v_business and journal_entry_id=v_journal_id;
 if v_count<>2 or v_debit<>50 or v_credit<>50 then
  raise exception 'Customer refund journal must balance receivable and cash';
 end if;

 perform public.post_customer_refund(
  v_business,v_return_id,v_account,60,current_date,'REF-2','final cash refund','customer-refund-key-002'
 );
 v_failed:=false;
 begin
  perform public.post_customer_refund(
   v_business,v_return_id,v_account,0.1,current_date,'REF-3','over refund','customer-refund-key-003'
  );
 exception when check_violation then v_failed:=true;
 end;
 if not v_failed then raise exception 'Refund cannot exceed the remaining sales return amount'; end if;

 v_failed:=false;
 perform set_config('request.jwt.claim.sub',v_outsider::text,true);
 begin
  perform public.post_customer_refund(
   v_business,v_return_id,v_account,1,current_date,'REF-X','outsider refund','customer-refund-outsider-01'
  );
 exception when insufficient_privilege then v_failed:=true;
 end;
 if not v_failed then raise exception 'Cross-business customer refund must be denied'; end if;
end;
$test$;

rollback;
