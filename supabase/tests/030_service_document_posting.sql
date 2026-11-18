-- 030: Service sales and purchases post balanced journals without inventory effects.
begin;

do $test$
declare
 v_owner uuid:='b1000000-0000-4000-8000-000000000001';
 v_outsider uuid:='b1000000-0000-4000-8000-000000000002';
 v_business uuid:='b2000000-0000-4000-8000-000000000001';
 v_other_business uuid:='b2000000-0000-4000-8000-000000000002';
 v_customer uuid;
 v_supplier uuid;
 v_service uuid;
 v_sale_doc uuid;
 v_purchase_doc uuid;
 v_other_doc uuid;
 v_sale_journal uuid;
 v_purchase_journal uuid;
 v_replay uuid;
 v_count integer;
 v_debit numeric;
 v_credit numeric;
 v_failed boolean:=false;
begin
 insert into auth.users(id,email,email_confirmed_at)
 values(v_owner,'service-post-owner@example.test',now()),(v_outsider,'service-post-outsider@example.test',now())
 on conflict(id) do nothing;
 insert into public.businesses(id,name,owner_user_id)
 values(v_business,'Service posting business',v_owner),(v_other_business,'Other service business',v_outsider)
 on conflict(id) do nothing;
 insert into public.business_members(business_id,user_id,role_code,status,joined_at)
 values(v_business,v_owner,'owner','active',now()),(v_other_business,v_outsider,'owner','active',now())
 on conflict(business_id,user_id) do nothing;
 insert into public.contacts(business_id,contact_type,name,legacy_id)
 values(v_business,'customer','Service customer','service-customer')
 returning id into v_customer;
 insert into public.contacts(business_id,contact_type,name,legacy_id)
 values(v_business,'supplier','Service supplier','service-supplier')
 returning id into v_supplier;
 insert into public.services(business_id,name,sale_price,legacy_id)
 values(v_business,'Consulting',1000,'service-consulting')
 returning id into v_service;

 insert into public.documents(
  business_id,document_type,contact_id,document_date,status,subtotal,discount_amount,
  taxable_amount,tax_amount,total_amount,notes
 ) values(
  v_business,'service_sale',v_customer,current_date,'draft',1000,0,1000,100,1100,'Service sale'
 ) returning id into v_sale_doc;
 insert into public.document_items(
  business_id,document_id,item_type,service_id,description_snapshot,quantity,unit_name_snapshot,
  unit_price,discount_amount,tax_rate_snapshot,tax_amount,line_total,sort_order
 ) values(
  v_business,v_sale_doc,'service',v_service,'Consulting',1,'خدمت',1000,0,10,100,1100,1
 );

 insert into public.documents(
  business_id,document_type,contact_id,document_date,status,subtotal,discount_amount,
  taxable_amount,tax_amount,total_amount,notes
 ) values(
  v_business,'service_purchase',v_supplier,current_date,'draft',500,0,500,50,550,'Service purchase'
 ) returning id into v_purchase_doc;
 insert into public.document_items(
  business_id,document_id,item_type,service_id,description_snapshot,quantity,unit_name_snapshot,
  unit_price,discount_amount,tax_rate_snapshot,tax_amount,line_total,sort_order
 ) values(
  v_business,v_purchase_doc,'service',v_service,'Consulting',1,'خدمت',500,0,10,50,550,1
 );

 insert into public.documents(
  business_id,document_type,contact_id,document_date,status,subtotal,discount_amount,
  taxable_amount,tax_amount,total_amount,notes
 ) values(
  v_business,'service_sale',v_customer,current_date,'draft',200,0,200,0,200,'Unauthorized draft'
 ) returning id into v_other_doc;
 insert into public.document_items(
  business_id,document_id,item_type,service_id,description_snapshot,quantity,unit_price,
  discount_amount,tax_rate_snapshot,tax_amount,line_total,sort_order
 ) values(v_business,v_other_doc,'service',v_service,'Consulting',1,200,0,0,0,200,1);

 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_sale_journal:=public.post_service_document(v_business,v_sale_doc,'service-sale-key-001');
 v_replay:=public.post_service_document(v_business,v_sale_doc,'service-sale-key-001');
 if v_sale_journal<>v_replay then raise exception 'Service sale retry must return the original journal'; end if;
 v_purchase_journal:=public.post_service_document(v_business,v_purchase_doc,'service-purchase-key-01');

 if (select status from public.documents where business_id=v_business and id=v_sale_doc)<>'posted'
  or (select status from public.documents where business_id=v_business and id=v_purchase_doc)<>'posted' then
  raise exception 'Service documents must be posted atomically';
 end if;
 if (select debit from public.contact_ledger_entries
  where business_id=v_business and document_id=v_sale_doc and entry_type='invoice_debit')<>1100 then
  raise exception 'Service-sale customer ledger mismatch';
 end if;
 if (select credit from public.contact_ledger_entries
  where business_id=v_business and document_id=v_purchase_doc and entry_type='invoice_credit')<>550 then
  raise exception 'Service-purchase supplier ledger mismatch';
 end if;

 select count(*),sum(debit),sum(credit) into v_count,v_debit,v_credit
 from public.journal_lines where business_id=v_business and journal_entry_id=v_sale_journal;
 if v_count<>3 or v_debit<>1100 or v_credit<>1100 then
  raise exception 'Service-sale journal must balance receivable, service revenue and tax';
 end if;
 select count(*),sum(debit),sum(credit) into v_count,v_debit,v_credit
 from public.journal_lines where business_id=v_business and journal_entry_id=v_purchase_journal;
 if v_count<>3 or v_debit<>550 or v_credit<>550 then
  raise exception 'Service-purchase journal must balance expense, recoverable tax and payable';
 end if;
 if exists(select 1 from public.stock_movements where business_id=v_business and document_id in(v_sale_doc,v_purchase_doc))
  or exists(select 1 from public.document_item_costs where business_id=v_business and document_item_id in(
    select id from public.document_items where business_id=v_business and document_id in(v_sale_doc,v_purchase_doc)
  )) then
  raise exception 'Service posting must not fabricate stock movements or item costs';
 end if;

 v_failed:=false;
 begin
  perform public.post_service_document(v_business,v_sale_doc,'service-sale-other-key');
 exception when unique_violation then v_failed:=true;
 end;
 if not v_failed then raise exception 'A posted service document cannot be posted with another key'; end if;

 v_failed:=false;
 perform set_config('request.jwt.claim.sub',v_outsider::text,true);
 begin
  perform public.post_service_document(v_business,v_other_doc,'outsider-service-key');
 exception when insufficient_privilege then v_failed:=true;
 end;
 if not v_failed then raise exception 'Cross-business service posting must be denied'; end if;
end;
$test$;

rollback;
