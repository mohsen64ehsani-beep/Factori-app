-- 030: Post service sales and service purchases without inventing inventory or service costs.
begin;

create or replace function public.post_service_document(
 p_business_id uuid,
 p_document_id uuid,
 p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
 v_user uuid:=auth.uid();
 v_doc record;
 v_item record;
 v_permission text;
 v_existing_journal_id uuid;
 v_existing_fingerprint text;
 v_fingerprint text;
 v_journal_id uuid;
 v_receivable_account_id uuid;
 v_revenue_account_id uuid;
 v_tax_payable_account_id uuid;
 v_tax_asset_account_id uuid;
 v_payable_account_id uuid;
 v_service_expense_account_id uuid;
 v_period_id uuid;
 v_item_count integer:=0;
 v_line_order integer:=0;
 v_subtotal numeric(30,0):=0;
 v_line_discounts numeric(30,0):=0;
 v_base_total numeric(30,0):=0;
 v_header_discount numeric(30,0):=0;
 v_allocated_header_discount numeric(30,0):=0;
 v_allocated_total numeric(30,0):=0;
 v_line_base numeric(30,0):=0;
 v_line_net numeric(30,0):=0;
 v_line_tax numeric(30,0):=0;
 v_tax numeric(30,0):=0;
 v_line_total numeric(30,0):=0;
 v_expected_tax numeric(30,0):=0;
 v_expected_total numeric(30,0):=0;
begin
 if v_user is null then
  raise exception using errcode='28000',message='Authentication required';
 end if;
 if p_business_id is null or p_document_id is null
   or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 160 then
  raise exception using errcode='22023',message='Business, service document and valid idempotency key are required';
 end if;

 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text||':service-document-post:'||p_idempotency_key,0));

 select d.* into v_doc
 from public.documents d
 where d.business_id=p_business_id and d.id=p_document_id
 for update;
 if not found then
  raise exception using errcode='P0002',message='Service document not found';
 end if;

 if v_doc.document_type not in ('service_sale','service_purchase') then
  raise exception using errcode='22023',message='Only service sales and service purchases are supported';
 end if;
 v_permission:=case when v_doc.document_type='service_sale' then 'sales.post' else 'purchases.post' end;
 if not private.has_business_permission(p_business_id,v_permission) then
  raise exception using errcode='42501',message='Service document posting is not permitted';
 end if;

 v_fingerprint:=md5(jsonb_build_array(
  v_doc.business_id,v_doc.id,v_doc.document_type,v_doc.contact_id,v_doc.warehouse_id,
  v_doc.fiscal_period_id,v_doc.document_date,v_doc.due_date,v_doc.subtotal,
  v_doc.discount_amount,v_doc.taxable_amount,v_doc.tax_amount,v_doc.total_amount,
  coalesce((select jsonb_agg(jsonb_build_object(
   'id',di.id,'item_type',di.item_type,'service_id',di.service_id,
   'description',di.description_snapshot,'quantity',di.quantity,'unit_price',di.unit_price,
   'discount',di.discount_amount,'tax_rate',di.tax_rate_snapshot,
   'tax_amount',di.tax_amount,'line_total',di.line_total
  ) order by di.sort_order,di.id)
  from public.document_items di
  where di.business_id=p_business_id and di.document_id=p_document_id),'[]'::jsonb)
 )::text);

 select dp.journal_entry_id,dp.request_fingerprint
 into v_existing_journal_id,v_existing_fingerprint
 from public.document_postings dp
 where dp.business_id=p_business_id and dp.idempotency_key=p_idempotency_key;
 if v_existing_journal_id is not null then
  if v_existing_fingerprint is distinct from v_fingerprint then
   raise exception using errcode='23505',message='Idempotency key was already used with different service document data';
  end if;
  if exists(select 1 from public.document_postings dp
    where dp.business_id=p_business_id and dp.id=p_document_id and dp.document_id<>p_document_id) then
   raise exception using errcode='23505',message='Idempotency key belongs to another document';
  end if;
  return v_existing_journal_id;
 end if;

 if v_doc.status<>'draft' then
  raise exception using errcode='55000',message='Only a draft service document can be posted';
 end if;
 if v_doc.contact_id is null or v_doc.warehouse_id is not null then
  raise exception using errcode='22023',message='Service document requires a contact and must not reference a stock warehouse';
 end if;
 if not exists(
  select 1 from public.contacts c
  where c.business_id=p_business_id and c.id=v_doc.contact_id and c.is_active
   and ((v_doc.document_type='service_sale' and c.contact_type in ('customer','both'))
     or (v_doc.document_type='service_purchase' and c.contact_type in ('supplier','both')))
 ) then
  raise exception using errcode='22023',message='Service document contact is missing, inactive, or has an incompatible role';
 end if;
 if exists(select 1 from public.document_postings dp
  where dp.business_id=p_business_id and dp.document_id=p_document_id) then
  raise exception using errcode='23505',message='Service document has already been posted';
 end if;

 if v_doc.fiscal_period_id is not null and not exists(
  select 1 from public.fiscal_periods fp
  where fp.business_id=p_business_id and fp.id=v_doc.fiscal_period_id
   and fp.status in ('open','reopened')
   and v_doc.document_date between fp.date_from and fp.date_to
 ) then
  raise exception using errcode='22023',message='Service document fiscal period is closed or date is outside the period';
 end if;

 select count(*),
  coalesce(sum(round(di.quantity*di.unit_price)),0),
  coalesce(sum(di.discount_amount),0),
  coalesce(sum(round(di.quantity*di.unit_price)-di.discount_amount),0),
  coalesce(sum(di.tax_amount),0),
  coalesce(sum(di.line_total),0)
 into v_item_count,v_subtotal,v_line_discounts,v_base_total,v_tax,v_line_total
 from public.document_items di
 where di.business_id=p_business_id and di.document_id=p_document_id;

 if v_item_count<1 or v_item_count>500
  or v_doc.total_amount<=0 or v_doc.taxable_amount<=0
  or v_doc.discount_amount<v_line_discounts then
  raise exception using errcode='22023',message='Service document has invalid or empty line items';
 end if;
 v_header_discount:=v_doc.discount_amount-v_line_discounts;
 if v_header_discount>v_base_total
  or v_base_total-v_header_discount<>v_doc.taxable_amount
  or v_tax<>v_doc.tax_amount
  or v_line_total<>v_doc.total_amount
  or v_doc.taxable_amount+v_doc.tax_amount<>v_doc.total_amount
  or v_subtotal<>v_doc.subtotal
  or v_subtotal-v_doc.discount_amount<>v_doc.taxable_amount then
  raise exception using errcode='23514',message='Service document totals do not reconcile';
 end if;

 if exists(
  select 1 from public.document_items di
  join public.services s on s.business_id=di.business_id and s.id=di.service_id
  where di.business_id=p_business_id and di.document_id=p_document_id
   and (di.item_type<>'service' or di.service_id is null or di.product_id is not null
    or not s.is_active or di.quantity<=0 or di.unit_price<0 or di.discount_amount<0
    or di.discount_amount>round(di.quantity*di.unit_price)
    or di.tax_rate_snapshot<0 or di.tax_rate_snapshot>100)
 ) or exists(
  select 1 from public.document_items di
  where di.business_id=p_business_id and di.document_id=p_document_id
   and (di.item_type<>'service' or di.service_id is null or di.product_id is not null)
 ) then
  raise exception using errcode='22023',message='Service document contains an invalid, inactive, or non-service line';
 end if;

 if v_doc.document_type='service_sale' then
  select id into v_receivable_account_id from public.chart_of_accounts
  where business_id=p_business_id and code='1100' and account_class='asset' and is_active and allow_posting;
  select id into v_revenue_account_id from public.chart_of_accounts
  where business_id=p_business_id and code='4100' and account_class='income' and is_active and allow_posting;
  select id into v_tax_payable_account_id from public.chart_of_accounts
  where business_id=p_business_id and code='2100' and account_class='liability' and is_active and allow_posting;
  if v_receivable_account_id is null or v_revenue_account_id is null or v_tax_payable_account_id is null then
   raise exception using errcode='55000',message='Service-sales ledger accounts are not configured';
  end if;
 else
  select id into v_service_expense_account_id from public.chart_of_accounts
  where business_id=p_business_id and code='5100' and account_class='expense' and is_active and allow_posting;
  select id into v_tax_asset_account_id from public.chart_of_accounts
  where business_id=p_business_id and code='1300' and account_class='asset' and is_active and allow_posting;
  select id into v_payable_account_id from public.chart_of_accounts
  where business_id=p_business_id and code='2000' and account_class='liability' and is_active and allow_posting;
  if v_service_expense_account_id is null or v_tax_asset_account_id is null or v_payable_account_id is null then
   raise exception using errcode='55000',message='Service-purchase ledger accounts are not configured';
  end if;
 end if;

 select fp.id into v_period_id
 from public.fiscal_periods fp
 where fp.business_id=p_business_id and v_doc.document_date between fp.date_from and fp.date_to
 order by fp.date_from desc limit 1;
 if v_period_id is not null and not exists(
  select 1 from public.fiscal_periods fp
  where fp.business_id=p_business_id and fp.id=v_period_id and fp.status in ('open','reopened')
 ) then
  raise exception using errcode='22023',message='Service document date is in a closed fiscal period';
 end if;

 v_line_order:=0;
 for v_item in
  select di.* from public.document_items di
  where di.business_id=p_business_id and di.document_id=p_document_id
  order by di.sort_order,di.id
 loop
  v_line_order:=v_line_order+1;
  v_line_base:=round(v_item.quantity*v_item.unit_price)-v_item.discount_amount;
  if v_line_order=v_item_count then
   v_allocated_header_discount:=v_header_discount-v_allocated_total;
  else
   v_allocated_header_discount:=case when v_base_total=0 then 0
    else floor(v_header_discount*v_line_base/v_base_total) end;
  end if;
  v_allocated_total:=v_allocated_total+v_allocated_header_discount;
  v_line_net:=greatest(0,v_line_base-v_allocated_header_discount);
  v_line_tax:=round(v_line_net*v_item.tax_rate_snapshot/100);
  if v_line_tax<>v_item.tax_amount or v_line_net+v_line_tax<>v_item.line_total then
   raise exception using errcode='23514',message='Service document line tax or total does not reconcile';
  end if;
  v_expected_tax:=v_expected_tax+v_line_tax;
  v_expected_total:=v_expected_total+v_line_net+v_line_tax;
 end loop;
 if v_expected_tax<>v_doc.tax_amount or v_expected_total<>v_doc.total_amount then
  raise exception using errcode='23514',message='Service document tax or total does not reconcile';
 end if;

 insert into public.journal_entries(
  business_id,entry_date,fiscal_period_id,source_type,source_id,description,
  status,idempotency_key,created_by
 ) values(
  p_business_id,v_doc.document_date,v_period_id,'document',p_document_id,
  coalesce(nullif(btrim(coalesce(v_doc.notes,'')),''),case when v_doc.document_type='service_sale' then 'فاکتور فروش خدمات' else 'فاکتور خرید خدمات' end),
  'draft','service-document-post:'||p_idempotency_key,v_user
 ) returning id into v_journal_id;

 if v_doc.document_type='service_sale' then
  insert into public.journal_lines(
   business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order
  ) values(
   p_business_id,v_journal_id,v_receivable_account_id,v_doc.contact_id,v_doc.total_amount,0,'مطالبات خدمات از مشتری',1
  ),(
   p_business_id,v_journal_id,v_revenue_account_id,null,0,v_doc.taxable_amount,'درآمد خدمات',2
  );
  if v_doc.tax_amount>0 then
   insert into public.journal_lines(
    business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order
   ) values(p_business_id,v_journal_id,v_tax_payable_account_id,null,0,v_doc.tax_amount,'مالیات خدمات پرداختنی',3);
  end if;
  insert into public.contact_ledger_entries(
   business_id,contact_id,entry_date,entry_type,debit,credit,document_id,description,source_legacy_id,created_by
  ) values(
   p_business_id,v_doc.contact_id,v_doc.document_date,'invoice_debit',v_doc.total_amount,0,p_document_id,
   coalesce(nullif(btrim(coalesce(v_doc.notes,'')),''),'فاکتور فروش خدمات'),
   'document_posting:'||p_document_id::text,v_user
  );
 else
  insert into public.journal_lines(
   business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order
  ) values(
   p_business_id,v_journal_id,v_service_expense_account_id,null,v_doc.taxable_amount,0,'هزینه خدمات خریداری‌شده',1
  ),(
   p_business_id,v_journal_id,v_payable_account_id,v_doc.contact_id,0,v_doc.total_amount,'بدهی به تأمین‌کننده',3
  );
  if v_doc.tax_amount>0 then
   insert into public.journal_lines(
    business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order
   ) values(p_business_id,v_journal_id,v_tax_asset_account_id,null,v_doc.tax_amount,0,'مالیات خرید خدمات',2);
  end if;
  insert into public.contact_ledger_entries(
   business_id,contact_id,entry_date,entry_type,debit,credit,document_id,description,source_legacy_id,created_by
  ) values(
   p_business_id,v_doc.contact_id,v_doc.document_date,'invoice_credit',0,v_doc.total_amount,p_document_id,
   coalesce(nullif(btrim(coalesce(v_doc.notes,'')),''),'فاکتور خرید خدمات'),
   'document_posting:'||p_document_id::text,v_user
  );
 end if;

 update public.journal_entries
 set status='posted',posted_at=now(),posted_by=v_user,version=version+1
 where business_id=p_business_id and id=v_journal_id;

 insert into public.document_postings(
  business_id,document_id,journal_entry_id,idempotency_key,request_fingerprint,created_by
 ) values(p_business_id,p_document_id,v_journal_id,p_idempotency_key,v_fingerprint,v_user);

 update public.documents
 set status='posted',posted_at=now(),version=version+1
 where business_id=p_business_id and id=p_document_id;

 return v_journal_id;
end;
$$;

revoke all on function public.post_service_document(uuid,uuid,text) from public,anon;
grant execute on function public.post_service_document(uuid,uuid,text) to authenticated;

commit;
