-- 036: Invoice-linked purchase returns and capped supplier cash refunds.
-- DEVELOPMENT DRAFT ONLY. Return stock only from the original remaining FIFO layer.
begin;

create table if not exists public.purchase_return_documents (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 original_document_id uuid not null,
 contact_id uuid not null,
 warehouse_id uuid not null,
 return_date date not null,
 reason text not null check(length(btrim(reason)) between 1 and 500),
 status text not null default 'draft' check(status in ('draft','posted')),
 taxable_amount numeric(20,0) not null default 0 check(taxable_amount>=0),
 tax_amount numeric(20,0) not null default 0 check(tax_amount>=0),
 total_amount numeric(20,0) not null default 0 check(total_amount>=0 and total_amount=taxable_amount+tax_amount),
 refunded_amount numeric(20,0) not null default 0 check(refunded_amount>=0 and refunded_amount<=total_amount),
 journal_entry_id uuid,
 idempotency_key text not null,
 request_fingerprint text not null,
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 posted_at timestamptz,
 unique(business_id,id),
 unique(business_id,idempotency_key),
 foreign key(business_id,original_document_id) references public.documents(business_id,id),
 foreign key(business_id,contact_id) references public.contacts(business_id,id),
 foreign key(business_id,warehouse_id) references public.warehouses(business_id,id),
 foreign key(business_id,journal_entry_id) references public.journal_entries(business_id,id)
);

create table if not exists public.purchase_return_items (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null,
 return_document_id uuid not null,
 original_document_item_id uuid not null,
 product_id uuid not null,
 quantity numeric(20,4) not null check(quantity>0),
 taxable_amount numeric(20,0) not null check(taxable_amount>=0),
 tax_amount numeric(20,0) not null check(tax_amount>=0),
 total_amount numeric(20,0) not null check(total_amount>=0 and total_amount=taxable_amount+tax_amount),
 stock_movement_id uuid not null,
 created_at timestamptz not null default now(),
 unique(business_id,id),
 unique(business_id,return_document_id,original_document_item_id),
 foreign key(business_id,return_document_id) references public.purchase_return_documents(business_id,id) on delete cascade,
 foreign key(business_id,original_document_item_id) references public.document_items(business_id,id),
 foreign key(business_id,product_id) references public.products(business_id,id),
 foreign key(business_id,stock_movement_id) references public.stock_movements(business_id,id)
);
create index if not exists purchase_return_items_original_idx
 on public.purchase_return_items(business_id,original_document_item_id);

alter table public.purchase_return_documents enable row level security;
alter table public.purchase_return_items enable row level security;
revoke all on public.purchase_return_documents,public.purchase_return_items from public,anon,authenticated;
grant select on public.purchase_return_documents,public.purchase_return_items to authenticated;

drop policy if exists purchase_return_documents_read on public.purchase_return_documents;
create policy purchase_return_documents_read on public.purchase_return_documents
 for select to authenticated using(private.has_business_permission(business_id,'purchases.read'));
drop policy if exists purchase_return_items_read on public.purchase_return_items;
create policy purchase_return_items_read on public.purchase_return_items
 for select to authenticated using(
  exists(select 1 from public.purchase_return_documents rd
   where rd.business_id=purchase_return_items.business_id
    and rd.id=purchase_return_items.return_document_id
    and private.has_business_permission(rd.business_id,'purchases.read'))
 );

create or replace function public.post_purchase_return(
 p_business_id uuid,p_original_document_id uuid,p_return_date date,
 p_items jsonb,p_reason text,p_idempotency_key text
)
returns uuid language plpgsql security definer set search_path=''
as $$
declare
 v_user uuid:=auth.uid();
 v_doc record; v_source record; v_layer record; v_item_json jsonb;
 v_source_item_id uuid; v_quantity numeric(20,4);
 v_existing_id uuid; v_existing_fingerprint text; v_fingerprint text; v_return_id uuid;
 v_stock_movement_id uuid; v_previous_qty numeric(20,4); v_previous_net numeric(20,0);
 v_previous_tax numeric(20,0); v_previous_allocated_qty numeric(20,4); v_previous_cost numeric(20,0);
 v_original_net numeric(20,0); v_line_net numeric(20,0); v_line_tax numeric(20,0);
 v_line_total numeric(20,0); v_cost_snapshot numeric(20,0); v_cost_total numeric(20,0);
 v_total_net numeric(20,0):=0; v_total_tax numeric(20,0):=0; v_total_amount numeric(20,0):=0;
 v_period_id uuid; v_journal_id uuid; v_payable_account_id uuid; v_inventory_account_id uuid;
 v_tax_account_id uuid; v_product_id uuid; v_item_count integer; v_distinct_items integer;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required'; end if;
 if not private.has_business_permission(p_business_id,'purchases.post')
  or not private.has_business_permission(p_business_id,'inventory.adjust') then
  raise exception using errcode='42501',message='Purchase return posting is not permitted';
 end if;
 if p_original_document_id is null or p_return_date is null or p_items is null
  or p_reason is null or length(btrim(p_reason)) not between 1 and 500
  or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 160 then
  raise exception using errcode='22023',message='Invalid purchase return request';
 end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)<1 or jsonb_array_length(p_items)>500 then
  raise exception using errcode='22023',message='Purchase return lines must be a JSON array with 1 to 500 items';
 end if;
 select count(*),count(distinct value->>'document_item_id')
 into v_item_count,v_distinct_items from jsonb_array_elements(p_items);
 if v_item_count<>v_distinct_items then
  raise exception using errcode='22023',message='A source purchase item may appear only once per return';
 end if;

 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text||':purchase-return:'||p_original_document_id::text,0));
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text||':purchase-return-key:'||p_idempotency_key,0));
 v_fingerprint:=md5(jsonb_build_array(p_business_id,p_original_document_id,p_return_date,p_items,btrim(p_reason))::text);
 select id,request_fingerprint into v_existing_id,v_existing_fingerprint
 from public.purchase_return_documents where business_id=p_business_id and idempotency_key=p_idempotency_key;
 if v_existing_id is not null then
  if v_existing_fingerprint is distinct from v_fingerprint then
   raise exception using errcode='23505',message='Purchase return idempotency key was used with different data';
  end if;
  return v_existing_id;
 end if;

 select d.* into v_doc from public.documents d
 where d.business_id=p_business_id and d.id=p_original_document_id for update;
 if not found then raise exception using errcode='P0002',message='Original purchase document not found'; end if;
 if v_doc.document_type<>'purchase' or v_doc.status<>'posted'
  or v_doc.contact_id is null or v_doc.warehouse_id is null then
  raise exception using errcode='22023',message='A posted purchase document with supplier and warehouse is required';
 end if;
 if p_return_date<v_doc.document_date then
  raise exception using errcode='22023',message='Purchase return date cannot precede the original purchase';
 end if;
 if not exists(select 1 from public.contacts c where c.business_id=p_business_id and c.id=v_doc.contact_id
  and c.is_active and c.contact_type in ('supplier','both')) then
  raise exception using errcode='22023',message='Original purchase supplier is invalid';
 end if;
 if not exists(select 1 from public.warehouses w where w.business_id=p_business_id and w.id=v_doc.warehouse_id and w.is_active) then
  raise exception using errcode='22023',message='Original purchase warehouse is inactive';
 end if;

 select fp.id into v_period_id from public.fiscal_periods fp
 where fp.business_id=p_business_id and p_return_date between fp.date_from and fp.date_to
 order by fp.date_from desc limit 1;
 if v_period_id is not null and not exists(select 1 from public.fiscal_periods fp
  where fp.business_id=p_business_id and fp.id=v_period_id and fp.status in ('open','reopened')) then
  raise exception using errcode='22023',message='Purchase return date is in a closed fiscal period';
 end if;

 for v_product_id in
  select distinct di.product_id from jsonb_array_elements(p_items) e
  join public.document_items di on di.business_id=p_business_id and di.document_id=p_original_document_id
   and di.id=(e.value->>'document_item_id')::uuid
  order by di.product_id
 loop
  perform 1 from public.products p where p.business_id=p_business_id and p.id=v_product_id
   and p.is_active and p.track_inventory for update;
  if not found then raise exception using errcode='22023',message='Purchase return product is missing, inactive or does not track inventory'; end if;
 end loop;

 insert into public.purchase_return_documents(
  business_id,original_document_id,contact_id,warehouse_id,return_date,reason,status,
  taxable_amount,tax_amount,total_amount,refunded_amount,idempotency_key,request_fingerprint,created_by
 ) values(p_business_id,p_original_document_id,v_doc.contact_id,v_doc.warehouse_id,p_return_date,
  btrim(p_reason),'draft',0,0,0,0,p_idempotency_key,v_fingerprint,v_user)
 returning id into v_return_id;

 for v_item_json in select value from jsonb_array_elements(p_items)
 loop
  if jsonb_typeof(v_item_json)<>'object' or nullif(v_item_json->>'document_item_id','') is null
   or nullif(v_item_json->>'quantity','') is null then
   raise exception using errcode='22023',message='Each purchase return line requires document_item_id and quantity';
  end if;
  begin
   v_source_item_id:=(v_item_json->>'document_item_id')::uuid;
   v_quantity:=(v_item_json->>'quantity')::numeric;
  exception when invalid_text_representation or numeric_value_out_of_range then
   raise exception using errcode='22023',message='Purchase return line contains an invalid item ID or quantity';
  end;
  if v_quantity::text in ('NaN','Infinity','-Infinity') or v_quantity<=0 then
   raise exception using errcode='22023',message='Purchase return quantity must be a positive finite number';
  end if;

  with lines as (
   select di.*,round(di.quantity*di.unit_price)-di.discount_amount as line_base,
    row_number() over(order by di.sort_order,di.id) as rn,count(*) over() as line_count,
    sum(round(di.quantity*di.unit_price)-di.discount_amount) over() as base_total,
    sum(di.discount_amount) over() as line_discounts
   from public.document_items di where di.business_id=p_business_id and di.document_id=p_original_document_id
  ), calculated as (
   select lines.*,
    case when rn=line_count then
     (v_doc.discount_amount-line_discounts)-coalesce(
      sum(floor((v_doc.discount_amount-line_discounts)*line_base/nullif(base_total,0)))
       over(order by rn rows between unbounded preceding and 1 preceding),0)
    else floor((v_doc.discount_amount-line_discounts)*line_base/nullif(base_total,0)) end
     as allocated_header_discount
   from lines
  )
  select * into v_source from calculated where id=v_source_item_id;
  if not found then raise exception using errcode='22023',message='Purchase return line does not belong to the original invoice'; end if;
  if v_source.item_type<>'goods' or v_source.product_id is null or v_source.service_id is not null then
   raise exception using errcode='22023',message='Purchase return line must reference a goods item on the original invoice';
  end if;

  select coalesce(sum(pri.quantity),0),coalesce(sum(pri.taxable_amount),0),coalesce(sum(pri.tax_amount),0)
  into v_previous_qty,v_previous_net,v_previous_tax
  from public.purchase_return_items pri join public.purchase_return_documents prd
   on prd.business_id=pri.business_id and prd.id=pri.return_document_id
  where pri.business_id=p_business_id and pri.original_document_item_id=v_source_item_id and prd.status='posted';
  if v_quantity>v_source.quantity-v_previous_qty then
   raise exception using errcode='23514',message='Purchase return quantity exceeds the unreturned quantity on the original invoice line';
  end if;

  v_original_net:=greatest(0,v_source.line_base-v_source.allocated_header_discount);
  v_line_net:=round(v_original_net*(v_previous_qty+v_quantity)/v_source.quantity)-v_previous_net;
  v_line_tax:=round(v_source.tax_amount*(v_previous_qty+v_quantity)/v_source.quantity)-v_previous_tax;
  v_line_total:=v_line_net+v_line_tax;
  if v_line_net<0 or v_line_tax<0 then raise exception using errcode='23514',message='Calculated purchase return amounts are invalid'; end if;

  select sm.id into v_stock_movement_id from public.stock_movements sm
  where sm.business_id=p_business_id and sm.document_id=p_original_document_id
   and sm.document_item_id=v_source_item_id and sm.movement_type='purchase' for update;
  if v_stock_movement_id is null then raise exception using errcode='55000',message='Original purchase stock movement is missing'; end if;

  select l.id,l.quantity_remaining,l.unit_cost,l.acquired_at into v_layer
  from public.inventory_cost_layers l
  where l.business_id=p_business_id and l.source_movement_id=v_stock_movement_id
   and l.product_id=v_source.product_id and l.warehouse_id=v_doc.warehouse_id for update;
  if not found then raise exception using errcode='55000',message='Original purchase FIFO cost layer is missing'; end if;
  select dic.total_cost_snapshot into v_cost_snapshot from public.document_item_costs dic
  where dic.business_id=p_business_id and dic.document_item_id=v_source_item_id;
  if v_cost_snapshot is null or round(v_source.quantity*v_layer.unit_cost)<>v_cost_snapshot then
   raise exception using errcode='23514',message='Original purchase FIFO layer does not reconcile exactly to the protected item cost; manual review is required';
  end if;
  if v_layer.quantity_remaining<v_quantity then
   raise exception using errcode='23514',message='Purchase return exceeds the remaining original FIFO layer in its source warehouse';
  end if;

  select coalesce(sum(ica.quantity),0),coalesce(sum(ica.total_cost),0)
  into v_previous_allocated_qty,v_previous_cost
  from public.inventory_cost_allocations ica
  join public.purchase_return_items pri on pri.business_id=ica.business_id and pri.stock_movement_id=ica.stock_movement_id
  join public.purchase_return_documents prd on prd.business_id=pri.business_id and prd.id=pri.return_document_id
  where ica.business_id=p_business_id and ica.layer_id=v_layer.id
   and pri.original_document_item_id=v_source_item_id and prd.status='posted';
  if v_previous_allocated_qty<>v_previous_qty then
   raise exception using errcode='55000',message='Purchase return quantity and FIFO allocation history do not reconcile';
  end if;
  v_cost_total:=round((v_previous_allocated_qty+v_quantity)*v_layer.unit_cost)-v_previous_cost;
  if v_cost_total<>v_line_net then
   raise exception using errcode='23514',message='Purchase return value does not reconcile with the original FIFO cost; manual review is required';
  end if;

  insert into public.stock_movements(
   business_id,product_id,warehouse_id,movement_type,quantity_delta,movement_date,
   document_id,document_item_id,idempotency_key,note,created_by
  ) values(p_business_id,v_source.product_id,v_doc.warehouse_id,'purchase_return',-v_quantity,
   p_return_date::timestamptz,p_original_document_id,v_source_item_id,
   'purchase-return:'||v_return_id::text||':'||v_source_item_id::text,btrim(p_reason),v_user)
  returning id into v_stock_movement_id;

  update public.inventory_cost_layers set quantity_remaining=quantity_remaining-v_quantity
  where business_id=p_business_id and id=v_layer.id and quantity_remaining>=v_quantity;
  if not found then raise exception using errcode='23514',message='Original FIFO layer changed during purchase return'; end if;

  insert into public.inventory_cost_allocations(business_id,layer_id,stock_movement_id,quantity,unit_cost,total_cost)
  values(p_business_id,v_layer.id,v_stock_movement_id,v_quantity,v_layer.unit_cost,v_cost_total);
  insert into public.purchase_return_items(
   business_id,return_document_id,original_document_item_id,product_id,quantity,
   taxable_amount,tax_amount,total_amount,stock_movement_id
  ) values(p_business_id,v_return_id,v_source_item_id,v_source.product_id,v_quantity,
   v_line_net,v_line_tax,v_line_total,v_stock_movement_id);

  v_total_net:=v_total_net+v_line_net;
  v_total_tax:=v_total_tax+v_line_tax;
  v_total_amount:=v_total_amount+v_line_total;
 end loop;

 if v_total_amount<=0 or v_total_net<=0 then raise exception using errcode='22023',message='A zero-value purchase return cannot be posted'; end if;
 select id into v_payable_account_id from public.chart_of_accounts
 where business_id=p_business_id and code='2000' and account_class='liability' and is_active and allow_posting;
 select id into v_inventory_account_id from public.chart_of_accounts
 where business_id=p_business_id and code='1200' and account_class='asset' and is_active and allow_posting;
 select id into v_tax_account_id from public.chart_of_accounts
 where business_id=p_business_id and code='1300' and account_class='asset' and is_active and allow_posting;
 if v_payable_account_id is null or v_inventory_account_id is null or (v_total_tax>0 and v_tax_account_id is null) then
  raise exception using errcode='55000',message='Purchase return ledger accounts are not configured';
 end if;

 insert into public.journal_entries(business_id,entry_date,fiscal_period_id,source_type,source_id,description,status,idempotency_key,created_by)
 values(p_business_id,p_return_date,v_period_id,'document',v_return_id,'مرجوعی خرید: '||btrim(p_reason),
  'draft','purchase-return-journal:'||p_idempotency_key,v_user) returning id into v_journal_id;
 insert into public.journal_lines(business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order)
 values(p_business_id,v_journal_id,v_payable_account_id,v_doc.contact_id,v_total_amount,0,'کاهش بدهی به تأمین‌کننده',1);
 insert into public.journal_lines(business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order)
 values(p_business_id,v_journal_id,v_inventory_account_id,null,0,v_total_net,'خروج موجودی بابت مرجوعی خرید',2);
 if v_total_tax>0 then
  insert into public.journal_lines(business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order)
  values(p_business_id,v_journal_id,v_tax_account_id,null,0,v_total_tax,'برگشت مالیات خریدنی',3);
 end if;
 update public.journal_entries set status='posted',posted_at=now(),posted_by=v_user,version=version+1
 where business_id=p_business_id and id=v_journal_id;
 insert into public.contact_ledger_entries(
  business_id,contact_id,entry_date,entry_type,debit,credit,document_id,description,source_legacy_id,created_by
 ) values(p_business_id,v_doc.contact_id,p_return_date,'purchase_return',v_total_amount,0,p_original_document_id,
  'مرجوعی خرید: '||btrim(p_reason),'purchase_return:'||v_return_id::text,v_user);
 update public.purchase_return_documents set status='posted',taxable_amount=v_total_net,tax_amount=v_total_tax,
  total_amount=v_total_amount,journal_entry_id=v_journal_id,posted_at=now()
 where business_id=p_business_id and id=v_return_id;
 return v_return_id;
end;
$$;

revoke all on function public.post_purchase_return(uuid,uuid,date,jsonb,text,text) from public,anon;
grant execute on function public.post_purchase_return(uuid,uuid,date,jsonb,text,text) to authenticated;

alter table public.financial_transactions drop constraint if exists financial_transactions_transaction_type_check;
alter table public.financial_transactions add constraint financial_transactions_transaction_type_check
 check(transaction_type in ('customer_receipt','supplier_payment','expense_payment','other_income','customer_refund',
  'supplier_refund','creditor_payment','account_transfer_in','account_transfer_out','cheque_deposit','opening_balance','adjustment'));

create table if not exists private.supplier_refund_allocations (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 purchase_return_document_id uuid not null,
 financial_transaction_id uuid not null,
 amount numeric(20,0) not null check(amount>0),
 idempotency_key text not null,
 request_fingerprint text not null,
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 unique(business_id,id),unique(business_id,financial_transaction_id),unique(business_id,idempotency_key),
 foreign key(business_id,purchase_return_document_id) references public.purchase_return_documents(business_id,id),
 foreign key(business_id,financial_transaction_id) references public.financial_transactions(business_id,id)
);
alter table private.supplier_refund_allocations enable row level security;
revoke all on private.supplier_refund_allocations from public,anon,authenticated;

create or replace function public.post_supplier_refund(
 p_business_id uuid,p_purchase_return_document_id uuid,p_financial_account_id uuid,
 p_amount numeric,p_transaction_date date,p_reference_number text,p_description text,p_idempotency_key text
)
returns uuid language plpgsql security definer set search_path=''
as $$
declare
 v_user uuid:=auth.uid(); v_contact_id uuid; v_return record;
 v_currency text; v_account_currency text; v_account_type text; v_cash_code text;
 v_cash_account_id uuid; v_payable_account_id uuid; v_refundable numeric(20,0);
 v_supplier_debit numeric(20,0); v_transaction_id uuid; v_existing_fingerprint text;
 v_fingerprint text; v_journal_id uuid; v_period_id uuid;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required'; end if;
 if not private.has_business_permission(p_business_id,'payments.create') then
  raise exception using errcode='42501',message='Supplier refund is not permitted';
 end if;
 if p_purchase_return_document_id is null or p_financial_account_id is null or p_amount is null
  or p_amount::text in ('NaN','Infinity','-Infinity') or p_amount<=0 or trunc(p_amount)<>p_amount
  or p_amount>999999999999999999 or p_transaction_date is null
  or length(btrim(coalesce(p_reference_number,'')))>120 or length(btrim(coalesce(p_description,'')))>500
  or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 160 then
  raise exception using errcode='22023',message='Invalid supplier refund fields';
 end if;
 select contact_id into v_contact_id from public.purchase_return_documents
 where business_id=p_business_id and id=p_purchase_return_document_id;
 if not found then raise exception using errcode='P0002',message='Purchase return document not found'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text||':supplier-refund-contact:'||v_contact_id::text,0));
 perform 1 from public.contacts c where c.business_id=p_business_id and c.id=v_contact_id for update;
 select * into v_return from public.purchase_return_documents prd
 where prd.business_id=p_business_id and prd.id=p_purchase_return_document_id for update;
 if not found or v_return.status<>'posted' then
  raise exception using errcode='55000',message='Only a posted purchase return can be refunded';
 end if;
 if p_transaction_date<v_return.return_date then
  raise exception using errcode='22023',message='Supplier refund date cannot precede the purchase return';
 end if;
 v_fingerprint:=md5(jsonb_build_array(p_business_id,p_purchase_return_document_id,p_financial_account_id,p_amount,
  p_transaction_date,nullif(btrim(coalesce(p_reference_number,'')),''),nullif(btrim(coalesce(p_description,'')),''))::text);
 select ft.id,ft.request_fingerprint into v_transaction_id,v_existing_fingerprint
 from public.financial_transactions ft where ft.business_id=p_business_id and ft.idempotency_key=p_idempotency_key;
 if v_transaction_id is not null then
  if v_existing_fingerprint is distinct from v_fingerprint or not exists(
   select 1 from private.supplier_refund_allocations a where a.business_id=p_business_id
    and a.financial_transaction_id=v_transaction_id and a.purchase_return_document_id=p_purchase_return_document_id) then
   raise exception using errcode='23505',message='Supplier refund idempotency key was used with different data';
  end if;
  return v_transaction_id;
 end if;
 v_refundable:=v_return.total_amount-v_return.refunded_amount;
 if p_amount>v_refundable then raise exception using errcode='23514',message='Supplier refund exceeds the remaining amount on this purchase return'; end if;
 select coalesce(sum(cle.debit-cle.credit),0) into v_supplier_debit
 from public.contact_ledger_entries cle where cle.business_id=p_business_id and cle.contact_id=v_return.contact_id;
 if p_amount>v_supplier_debit then raise exception using errcode='23514',message='Supplier does not have enough net debit balance for this cash refund'; end if;

 select coalesce(bs.currency_code,'IRR') into v_currency from public.business_settings bs where bs.business_id=p_business_id;
 v_currency:=coalesce(v_currency,'IRR');
 select fa.currency_code,fa.account_type into v_account_currency,v_account_type
 from public.financial_accounts fa where fa.business_id=p_business_id and fa.id=p_financial_account_id and fa.is_active for update;
 if not found or v_account_currency<>v_currency then
  raise exception using errcode='22023',message='Financial account is missing, inactive, or uses a different currency';
 end if;
 v_cash_code:=case v_account_type when 'cash' then '1000' when 'bank' then '1010' when 'wallet' then '1020' when 'clearing' then '1030' else null end;
 if v_cash_code is null then raise exception using errcode='22023',message='Unsupported financial account type'; end if;
 select m.chart_account_id into v_cash_account_id from public.financial_account_ledger_map m
 join public.chart_of_accounts coa on coa.business_id=m.business_id and coa.id=m.chart_account_id
 where m.business_id=p_business_id and m.financial_account_id=p_financial_account_id
  and coa.code=v_cash_code and coa.account_class='asset' and coa.is_active and coa.allow_posting;
 select id into v_payable_account_id from public.chart_of_accounts
 where business_id=p_business_id and code='2000' and account_class='liability' and is_active and allow_posting;
 if v_cash_account_id is null or v_payable_account_id is null then
  raise exception using errcode='55000',message='Supplier refund ledger accounts are not configured';
 end if;
 select fp.id into v_period_id from public.fiscal_periods fp
 where fp.business_id=p_business_id and p_transaction_date between fp.date_from and fp.date_to
 order by fp.date_from desc limit 1;
 if v_period_id is not null and not exists(select 1 from public.fiscal_periods fp
  where fp.business_id=p_business_id and fp.id=v_period_id and fp.status in ('open','reopened')) then
  raise exception using errcode='22023',message='Supplier refund date is in a closed fiscal period';
 end if;

 insert into public.financial_transactions(
  business_id,transaction_type,direction,amount,currency_code,transaction_date,account_id,contact_id,document_id,
  reference_number,description,status,idempotency_key,request_fingerprint,created_by
 ) values(p_business_id,'supplier_refund','in',p_amount,v_currency,p_transaction_date,p_financial_account_id,
  v_return.contact_id,v_return.original_document_id,nullif(btrim(coalesce(p_reference_number,'')),''),
  coalesce(nullif(btrim(coalesce(p_description,'')),''),'دریافت وجه از تأمین‌کننده بابت مرجوعی'),
  'posted',p_idempotency_key,v_fingerprint,v_user) returning id into v_transaction_id;
 insert into public.journal_entries(
  business_id,entry_date,fiscal_period_id,source_type,source_id,description,status,idempotency_key,created_by
 ) values(p_business_id,p_transaction_date,v_period_id,'financial_transaction',v_transaction_id,
  coalesce(nullif(btrim(coalesce(p_description,'')),''),'دریافت وجه از تأمین‌کننده بابت مرجوعی'),
  'draft','supplier-refund-journal:'||p_idempotency_key,v_user) returning id into v_journal_id;
 insert into public.journal_lines(business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order)
 values
  (p_business_id,v_journal_id,v_cash_account_id,null,p_amount,0,'دریافت وجه از تأمین‌کننده',1),
  (p_business_id,v_journal_id,v_payable_account_id,v_return.contact_id,0,p_amount,'تسویه طلب از تأمین‌کننده',2);
 update public.journal_entries set status='posted',posted_at=now(),posted_by=v_user,version=version+1
 where business_id=p_business_id and id=v_journal_id;
 insert into public.contact_ledger_entries(
  business_id,contact_id,entry_date,entry_type,debit,credit,transaction_id,document_id,description,source_legacy_id,created_by
 ) values(p_business_id,v_return.contact_id,p_transaction_date,'adjustment_credit',0,p_amount,v_transaction_id,
  v_return.original_document_id,coalesce(nullif(btrim(coalesce(p_description,'')),''),'دریافت وجه از تأمین‌کننده بابت مرجوعی'),
  'financial_transaction:'||v_transaction_id::text,v_user);
 insert into private.supplier_refund_allocations(
  business_id,purchase_return_document_id,financial_transaction_id,amount,idempotency_key,request_fingerprint,created_by
 ) values(p_business_id,p_purchase_return_document_id,v_transaction_id,p_amount,p_idempotency_key,v_fingerprint,v_user);
 update public.purchase_return_documents set refunded_amount=refunded_amount+p_amount
 where business_id=p_business_id and id=p_purchase_return_document_id;
 return v_transaction_id;
end;
$$;

revoke all on function public.post_supplier_refund(uuid,uuid,uuid,numeric,date,text,text,text) from public,anon;
grant execute on function public.post_supplier_refund(uuid,uuid,uuid,numeric,date,text,text,text) to authenticated;

commit;
