-- 034: Post goods sales returns only against the exact original posted invoice item and FIFO cost allocations.
begin;

create table if not exists public.sales_return_documents (
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

create table if not exists public.sales_return_items (
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
 foreign key(business_id,return_document_id) references public.sales_return_documents(business_id,id) on delete cascade,
 foreign key(business_id,original_document_item_id) references public.document_items(business_id,id),
 foreign key(business_id,product_id) references public.products(business_id,id),
 foreign key(business_id,stock_movement_id) references public.stock_movements(business_id,id)
);
create index if not exists sales_return_items_original_idx
 on public.sales_return_items(business_id,original_document_item_id);

create table if not exists private.sales_return_cost_allocations (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null,
 return_item_id uuid not null,
 original_cost_allocation_id uuid not null,
 return_cost_layer_id uuid not null,
 quantity numeric(20,4) not null check(quantity>0),
 unit_cost numeric(20,0) not null check(unit_cost>=0),
 total_cost numeric(20,0) not null check(total_cost>=0),
 created_at timestamptz not null default now(),
 unique(business_id,id),
 unique(business_id,return_item_id,original_cost_allocation_id),
 foreign key(business_id,return_item_id) references public.sales_return_items(business_id,id) on delete cascade,
 foreign key(business_id,original_cost_allocation_id) references public.inventory_cost_allocations(business_id,id),
 foreign key(business_id,return_cost_layer_id) references public.inventory_cost_layers(business_id,id)
);
create index if not exists sales_return_cost_allocations_original_idx
 on private.sales_return_cost_allocations(business_id,original_cost_allocation_id);

alter table public.sales_return_documents enable row level security;
alter table public.sales_return_items enable row level security;
alter table private.sales_return_cost_allocations enable row level security;
revoke all on public.sales_return_documents,public.sales_return_items from public,anon,authenticated;
grant select on public.sales_return_documents,public.sales_return_items to authenticated;
revoke all on private.sales_return_cost_allocations from public,anon,authenticated;

drop policy if exists sales_return_documents_read on public.sales_return_documents;
create policy sales_return_documents_read on public.sales_return_documents
 for select to authenticated using(private.has_business_permission(business_id,'sales.read'));
drop policy if exists sales_return_items_read on public.sales_return_items;
create policy sales_return_items_read on public.sales_return_items
 for select to authenticated using(
  exists(select 1 from public.sales_return_documents rd
   where rd.business_id=sales_return_items.business_id
    and rd.id=sales_return_items.return_document_id
    and private.has_business_permission(rd.business_id,'sales.read'))
 );

create or replace function public.post_sales_return(
 p_business_id uuid,
 p_original_document_id uuid,
 p_return_date date,
 p_items jsonb,
 p_reason text,
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
 v_existing_id uuid;
 v_existing_fingerprint text;
 v_fingerprint text;
 v_return_id uuid;
 v_return_item_id uuid;
 v_item_json jsonb;
 v_source_item_id uuid;
 v_quantity numeric(20,4);
 v_source record;
 v_previous_qty numeric(20,4);
 v_previous_net numeric(20,0);
 v_previous_tax numeric(20,0);
 v_original_net numeric(20,0);
 v_line_net numeric(20,0);
 v_line_tax numeric(20,0);
 v_line_total numeric(20,0);
 v_original_movement_id uuid;
 v_stock_movement_id uuid;
 v_alloc record;
 v_previous_allocated numeric(20,4);
 v_available numeric(20,4);
 v_remaining numeric(20,4);
 v_take numeric(20,4);
 v_cost_total numeric(20,0);
 v_total_net numeric(20,0):=0;
 v_total_tax numeric(20,0):=0;
 v_total_amount numeric(20,0):=0;
 v_total_cost numeric(20,0):=0;
 v_new_layer_id uuid;
 v_period_id uuid;
 v_journal_id uuid;
 v_revenue_account_id uuid;
 v_tax_account_id uuid;
 v_receivable_account_id uuid;
 v_inventory_account_id uuid;
 v_cogs_account_id uuid;
 v_line_order integer:=0;
 v_item_count integer;
 v_distinct_items integer;
begin
 if v_user is null then
  raise exception using errcode='28000',message='Authentication required';
 end if;
 if not private.has_business_permission(p_business_id,'sales.post')
  or not private.has_business_permission(p_business_id,'inventory.adjust') then
  raise exception using errcode='42501',message='Sales return posting is not permitted';
 end if;
 if p_original_document_id is null or p_return_date is null
  or p_items is null or jsonb_typeof(p_items)<>'array'
  or jsonb_array_length(p_items)<1 or jsonb_array_length(p_items)>500
  or p_reason is null or length(btrim(p_reason)) not between 1 and 500
  or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 160 then
  raise exception using errcode='22023',message='Invalid sales return request';
 end if;

 select count(*),count(distinct value->>'document_item_id')
 into v_item_count,v_distinct_items
 from jsonb_array_elements(p_items);
 if v_item_count<>v_distinct_items then
  raise exception using errcode='22023',message='A source invoice item may appear only once per return';
 end if;

 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text||':sales-return:'||p_original_document_id::text,0));
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text||':sales-return-key:'||p_idempotency_key,0));

 v_fingerprint:=md5(jsonb_build_array(
  p_business_id,p_original_document_id,p_return_date,p_items,btrim(p_reason)
 )::text);
 select id,request_fingerprint into v_existing_id,v_existing_fingerprint
 from public.sales_return_documents
 where business_id=p_business_id and idempotency_key=p_idempotency_key;
 if v_existing_id is not null then
  if v_existing_fingerprint is distinct from v_fingerprint then
   raise exception using errcode='23505',message='Sales return idempotency key was used with different data';
  end if;
  return v_existing_id;
 end if;

 select d.* into v_doc from public.documents d
 where d.business_id=p_business_id and d.id=p_original_document_id
 for update;
 if not found or v_doc.document_type<>'goods_sale' or v_doc.status<>'posted'
  or v_doc.contact_id is null or v_doc.warehouse_id is null then
  raise exception using errcode='22023',message='A posted goods-sale document with customer and warehouse is required';
 end if;
 if p_return_date<v_doc.document_date then
  raise exception using errcode='22023',message='Return date cannot precede the original sale';
 end if;
 if not exists(select 1 from public.contacts c
  where c.business_id=p_business_id and c.id=v_doc.contact_id
   and c.contact_type in ('customer','both')) then
  raise exception using errcode='22023',message='Original sale customer is invalid';
 end if;
 if not exists(select 1 from public.warehouses w
  where w.business_id=p_business_id and w.id=v_doc.warehouse_id and w.is_active) then
  raise exception using errcode='22023',message='Original sale warehouse is inactive';
 end if;

 select fp.id into v_period_id from public.fiscal_periods fp
 where fp.business_id=p_business_id and p_return_date between fp.date_from and fp.date_to
 order by fp.date_from desc limit 1;
 if v_period_id is not null and not exists(
  select 1 from public.fiscal_periods fp
  where fp.business_id=p_business_id and fp.id=v_period_id and fp.status in ('open','reopened')
 ) then
  raise exception using errcode='22023',message='Sales return date is in a closed fiscal period';
 end if;

 insert into public.sales_return_documents(
  business_id,original_document_id,contact_id,warehouse_id,return_date,reason,
  status,taxable_amount,tax_amount,total_amount,idempotency_key,request_fingerprint,created_by
 ) values(
  p_business_id,p_original_document_id,v_doc.contact_id,v_doc.warehouse_id,p_return_date,
  btrim(p_reason),'draft',0,0,0,p_idempotency_key,v_fingerprint,v_user
 ) returning id into v_return_id;

 for v_item_json in select value from jsonb_array_elements(p_items)
 loop
  if jsonb_typeof(v_item_json)<>'object'
   or nullif(v_item_json->>'document_item_id','') is null
   or nullif(v_item_json->>'quantity','') is null then
   raise exception using errcode='22023',message='Each return line requires document_item_id and quantity';
  end if;
  begin
   v_source_item_id:=(v_item_json->>'document_item_id')::uuid;
   v_quantity:=(v_item_json->>'quantity')::numeric;
  exception when invalid_text_representation or numeric_value_out_of_range then
   raise exception using errcode='22023',message='Return line contains an invalid item ID or quantity';
  end;
  if v_quantity::text in ('NaN','Infinity','-Infinity') or v_quantity<=0 then
   raise exception using errcode='22023',message='Return quantity must be a positive finite number';
  end if;

  with lines as (
   select di.*,
    round(di.quantity*di.unit_price)-di.discount_amount as line_base,
    row_number() over(order by di.sort_order,di.id) as rn,
    count(*) over() as line_count,
    sum(round(di.quantity*di.unit_price)-di.discount_amount) over() as base_total,
    sum(di.discount_amount) over() as line_discounts
   from public.document_items di
   where di.business_id=p_business_id and di.document_id=p_original_document_id
  ), calculated as (
   select lines.*,
    (v_doc.discount_amount-line_discounts) as header_discount,
    case when rn=line_count then
     (v_doc.discount_amount-line_discounts)-coalesce(
      sum(floor((v_doc.discount_amount-line_discounts)*line_base/nullif(base_total,0)))
       over(order by rn rows between unbounded preceding and 1 preceding),0)
     else floor((v_doc.discount_amount-line_discounts)*line_base/nullif(base_total,0))
    end as allocated_header_discount
   from lines
  )
  select * into v_source from calculated where id=v_source_item_id;

  if not found or v_source.item_type<>'goods' or v_source.product_id is null or v_source.service_id is not null then
   raise exception using errcode='22023',message='Return line must reference a goods item on the original invoice';
  end if;

  select coalesce(sum(sri.quantity),0),coalesce(sum(sri.taxable_amount),0),coalesce(sum(sri.tax_amount),0)
  into v_previous_qty,v_previous_net,v_previous_tax
  from public.sales_return_items sri
  join public.sales_return_documents srd
   on srd.business_id=sri.business_id and srd.id=sri.return_document_id
  where sri.business_id=p_business_id and sri.original_document_item_id=v_source_item_id
   and srd.status='posted';

  if v_quantity>v_source.quantity-v_previous_qty then
   raise exception using errcode='23514',message='Return quantity exceeds the unreturned quantity on the original invoice line';
  end if;

  v_original_net:=greatest(0,v_source.line_base-v_source.allocated_header_discount);
  v_line_net:=round(v_original_net*(v_previous_qty+v_quantity)/v_source.quantity)-v_previous_net;
  v_line_tax:=round(v_source.tax_amount*(v_previous_qty+v_quantity)/v_source.quantity)-v_previous_tax;
  v_line_total:=v_line_net+v_line_tax;
  if v_line_net<0 or v_line_tax<0 then
   raise exception using errcode='23514',message='Calculated return amounts are invalid';
  end if;

  select sm.id into v_original_movement_id
  from public.stock_movements sm
  where sm.business_id=p_business_id and sm.document_id=p_original_document_id
   and sm.document_item_id=v_source_item_id and sm.movement_type='sale'
  for update;
  if v_original_movement_id is null then
   raise exception using errcode='55000',message='Original sale stock movement is missing';
  end if;

  insert into public.stock_movements(
   business_id,product_id,warehouse_id,movement_type,quantity_delta,movement_date,
   document_id,document_item_id,idempotency_key,note,created_by
  ) values(
   p_business_id,v_source.product_id,v_doc.warehouse_id,'sales_return',v_quantity,
   p_return_date::timestamptz,p_original_document_id,v_source_item_id,
   'sales-return:'||v_return_id::text||':'||v_source_item_id::text,
   btrim(p_reason),v_user
  ) returning id into v_stock_movement_id;

  insert into public.sales_return_items(
   business_id,return_document_id,original_document_item_id,product_id,quantity,
   taxable_amount,tax_amount,total_amount,stock_movement_id
  ) values(
   p_business_id,v_return_id,v_source_item_id,v_source.product_id,v_quantity,
   v_line_net,v_line_tax,v_line_total,v_stock_movement_id
  ) returning id into v_return_item_id;

  v_remaining:=v_quantity;
  for v_alloc in
   select ica.id,ica.quantity,ica.unit_cost,layer.acquired_at
   from public.inventory_cost_allocations ica
   join public.inventory_cost_layers layer
    on layer.business_id=ica.business_id and layer.id=ica.layer_id
   where ica.business_id=p_business_id and ica.stock_movement_id=v_original_movement_id
   order by layer.acquired_at,layer.id,ica.id
   for update of ica
  loop
   exit when v_remaining<=0;
   select coalesce(sum(sca.quantity),0) into v_previous_allocated
   from private.sales_return_cost_allocations sca
   where sca.business_id=p_business_id and sca.original_cost_allocation_id=v_alloc.id;
   v_available:=v_alloc.quantity-v_previous_allocated;
   if v_available<=0 then continue; end if;
   v_take:=least(v_remaining,v_available);
   v_cost_total:=round(v_take*v_alloc.unit_cost);
   insert into public.inventory_cost_layers(
    business_id,product_id,warehouse_id,source_movement_id,
    quantity_in,quantity_remaining,unit_cost,acquired_at
   ) values(
    p_business_id,v_source.product_id,v_doc.warehouse_id,v_stock_movement_id,
    v_take,v_take,v_alloc.unit_cost,v_alloc.acquired_at
   ) returning id into v_new_layer_id;
   insert into private.sales_return_cost_allocations(
    business_id,return_item_id,original_cost_allocation_id,return_cost_layer_id,
    quantity,unit_cost,total_cost
   ) values(
    p_business_id,v_return_item_id,v_alloc.id,v_new_layer_id,
    v_take,v_alloc.unit_cost,v_cost_total
   );
   v_total_cost:=v_total_cost+v_cost_total;
   v_remaining:=v_remaining-v_take;
  end loop;
  if v_remaining>0 then
   raise exception using errcode='23514',message='Return quantity exceeds the original FIFO cost allocations';
  end if;

  v_total_net:=v_total_net+v_line_net;
  v_total_tax:=v_total_tax+v_line_tax;
  v_total_amount:=v_total_amount+v_line_total;
 end loop;

 if v_total_amount=0 and v_total_cost=0 then
  raise exception using errcode='22023',message='A zero-value, zero-cost return cannot be posted';
 end if;

 select id into v_revenue_account_id from public.chart_of_accounts
 where business_id=p_business_id and code='4000' and account_class='income' and is_active and allow_posting;
 select id into v_tax_account_id from public.chart_of_accounts
 where business_id=p_business_id and code='2100' and account_class='liability' and is_active and allow_posting;
 select id into v_receivable_account_id from public.chart_of_accounts
 where business_id=p_business_id and code='1100' and account_class='asset' and is_active and allow_posting;
 select id into v_inventory_account_id from public.chart_of_accounts
 where business_id=p_business_id and code='1200' and account_class='asset' and is_active and allow_posting;
 select id into v_cogs_account_id from public.chart_of_accounts
 where business_id=p_business_id and code='5000' and account_class='expense' and is_active and allow_posting;
 if (v_total_net>0 and v_revenue_account_id is null)
  or (v_total_tax>0 and v_tax_account_id is null)
  or (v_total_amount>0 and v_receivable_account_id is null)
  or (v_total_cost>0 and (v_inventory_account_id is null or v_cogs_account_id is null)) then
  raise exception using errcode='55000',message='Sales return ledger accounts are not configured';
 end if;

 insert into public.journal_entries(
  business_id,entry_date,fiscal_period_id,source_type,source_id,description,
  status,idempotency_key,created_by
 ) values(
  p_business_id,p_return_date,v_period_id,'document',v_return_id,
  'مرجوعی فروش: '||btrim(p_reason),'draft','sales-return-journal:'||p_idempotency_key,v_user
 ) returning id into v_journal_id;

 if v_total_net>0 then
  v_line_order:=v_line_order+1;
  insert into public.journal_lines(
   business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order
  ) values(p_business_id,v_journal_id,v_revenue_account_id,null,v_total_net,0,'برگشت از درآمد فروش',v_line_order);
 end if;
 if v_total_tax>0 then
  v_line_order:=v_line_order+1;
  insert into public.journal_lines(
   business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order
  ) values(p_business_id,v_journal_id,v_tax_account_id,null,v_total_tax,0,'کاهش مالیات فروش پرداختنی',v_line_order);
 end if;
 if v_total_amount>0 then
  v_line_order:=v_line_order+1;
  insert into public.journal_lines(
   business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order
  ) values(p_business_id,v_journal_id,v_receivable_account_id,v_doc.contact_id,0,v_total_amount,'اعتبار مرجوعی مشتری',v_line_order);
 end if;
 if v_total_cost>0 then
  v_line_order:=v_line_order+1;
  insert into public.journal_lines(
   business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order
  ) values
   (p_business_id,v_journal_id,v_inventory_account_id,null,v_total_cost,0,'بازگشت موجودی کالا',v_line_order),
   (p_business_id,v_journal_id,v_cogs_account_id,null,0,v_total_cost,'برگشت بهای تمام‌شده فروش',v_line_order+1);
 end if;

 update public.journal_entries
 set status='posted',posted_at=now(),posted_by=v_user,version=version+1
 where business_id=p_business_id and id=v_journal_id;

 if v_total_amount>0 then
  insert into public.contact_ledger_entries(
   business_id,contact_id,entry_date,entry_type,debit,credit,document_id,description,source_legacy_id,created_by
  ) values(
   p_business_id,v_doc.contact_id,p_return_date,'sales_return',0,v_total_amount,
   p_original_document_id,'مرجوعی فروش: '||btrim(p_reason),
   'sales_return:'||v_return_id::text,v_user
  );
 end if;

 update public.sales_return_documents
 set status='posted',taxable_amount=v_total_net,tax_amount=v_total_tax,
  total_amount=v_total_amount,journal_entry_id=v_journal_id,posted_at=now()
 where business_id=p_business_id and id=v_return_id;

 return v_return_id;
end;
$$;

revoke all on function public.post_sales_return(uuid,uuid,date,jsonb,text,text) from public,anon;
grant execute on function public.post_sales_return(uuid,uuid,date,jsonb,text,text) to authenticated;

commit;
