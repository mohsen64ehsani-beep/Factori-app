-- 019: Atomic purchase-document posting into inventory, FIFO layers, supplier ledger and GL.
-- DEVELOPMENT DRAFT ONLY. No legacy purchase records are replayed by this migration.
begin;

create table if not exists public.document_postings (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  document_id uuid not null,
  journal_entry_id uuid not null,
  idempotency_key text not null,
  request_fingerprint text not null,
  posted_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  unique(business_id,id),
  unique(business_id,document_id),
  unique(business_id,idempotency_key),
  foreign key(business_id,document_id) references public.documents(business_id,id),
  foreign key(business_id,journal_entry_id) references public.journal_entries(business_id,id)
);
alter table public.document_postings enable row level security;
revoke all on public.document_postings from public,anon,authenticated;

create or replace function public.post_purchase_document(
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
  v_existing_journal_id uuid;
  v_existing_fingerprint text;
  v_fingerprint text;
  v_journal_id uuid;
  v_inventory_account_id uuid;
  v_tax_account_id uuid;
  v_payable_account_id uuid;
  v_supplier_id uuid;
  v_warehouse_id uuid;
  v_period_id uuid;
  v_item_count integer:=0;
  v_line_order integer:=0;
  v_subtotal numeric(30,0):=0;
  v_line_discounts numeric(30,0):=0;
  v_header_discount numeric(30,0):=0;
  v_base_total numeric(30,0):=0;
  v_allocated_header_discount numeric(30,0):=0;
  v_allocated_total numeric(30,0):=0;
  v_line_base numeric(30,0):=0;
  v_line_cost numeric(30,0):=0;
  v_quantity numeric(20,4);
  v_unit_cost numeric(20,0);
  v_tax numeric(30,0):=0;
  v_expected_tax numeric(30,0):=0;
  v_line_tax numeric(30,0):=0;
  v_line_total numeric(30,0):=0;
  v_expected_total numeric(30,0):=0;
  v_inventory_total numeric(30,0):=0;
  v_document_total numeric(30,0):=0;
begin
  if v_user is null then
    raise exception using errcode='28000',message='Authentication required';
  end if;
  if not private.has_business_permission(p_business_id,'purchases.post') then
    raise exception using errcode='42501',message='Purchase posting is not permitted';
  end if;
  if p_document_id is null or p_idempotency_key is null
    or length(p_idempotency_key) not between 8 and 160 then
    raise exception using errcode='22023',message='Document and valid idempotency key are required';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_business_id::text||':purchase-post:'||p_idempotency_key,0));

  select d.* into v_doc
  from public.documents d
  where d.business_id=p_business_id and d.id=p_document_id
  for update;
  if not found then
    raise exception using errcode='P0002',message='Purchase document not found';
  end if;

  v_fingerprint:=md5(jsonb_build_array(
    v_doc.business_id,v_doc.id,v_doc.document_type,v_doc.contact_id,v_doc.warehouse_id,
    v_doc.fiscal_period_id,v_doc.document_date,v_doc.due_date,v_doc.subtotal,
    v_doc.discount_amount,v_doc.taxable_amount,v_doc.tax_amount,v_doc.total_amount,
    coalesce((select jsonb_agg(jsonb_build_object(
      'id',di.id,'item_type',di.item_type,'product_id',di.product_id,
      'description',di.description_snapshot,'quantity',di.quantity,'unit_price',di.unit_price,
      'discount',di.discount_amount,'tax_rate',di.tax_rate_snapshot,
      'tax_amount',di.tax_amount,'line_total',di.line_total
    ) order by di.sort_order,di.id)
    from public.document_items di
    where di.business_id=p_business_id and di.document_id=p_document_id),'[]'::jsonb)
  )::text);

  select dp.journal_entry_id,dp.request_fingerprint into v_existing_journal_id,v_existing_fingerprint
  from public.document_postings dp
  where dp.business_id=p_business_id and dp.idempotency_key=p_idempotency_key;
  if v_existing_journal_id is not null then
    if v_existing_fingerprint is distinct from v_fingerprint then
      raise exception using errcode='23505',message='Idempotency key was already used with different purchase data';
    end if;
    return v_existing_journal_id;
  end if;

  if v_doc.status<>'draft' or v_doc.document_type<>'purchase' then
    raise exception using errcode='55000',message='Only a draft purchase document can be posted';
  end if;
  if v_doc.contact_id is null or v_doc.warehouse_id is null then
    raise exception using errcode='22023',message='Purchase requires a supplier and destination warehouse';
  end if;
  if not exists(
    select 1 from public.contacts c
    where c.business_id=p_business_id and c.id=v_doc.contact_id and c.is_active
      and c.contact_type in ('supplier','both')
  ) then
    raise exception using errcode='22023',message='Supplier contact is missing, inactive, or not a supplier';
  end if;
  if not exists(
    select 1 from public.warehouses w
    where w.business_id=p_business_id and w.id=v_doc.warehouse_id and w.is_active
    for update
  ) then
    raise exception using errcode='22023',message='Destination warehouse is missing or inactive';
  end if;
  if exists(select 1 from public.document_postings dp
    where dp.business_id=p_business_id and dp.document_id=p_document_id) then
    raise exception using errcode='23505',message='Purchase document has already been posted';
  end if;

  if v_doc.fiscal_period_id is not null and not exists(
    select 1 from public.fiscal_periods fp
    where fp.business_id=p_business_id and fp.id=v_doc.fiscal_period_id
      and fp.status in ('open','reopened')
      and v_doc.document_date between fp.date_from and fp.date_to
  ) then
    raise exception using errcode='22023',message='Purchase document fiscal period is closed or date is outside the period';
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
    raise exception using errcode='22023',message='Purchase document has invalid or empty line items';
  end if;
  v_header_discount:=v_doc.discount_amount-v_line_discounts;
  if v_header_discount>v_base_total
    or v_base_total-v_header_discount<>v_doc.taxable_amount
    or v_tax<>v_doc.tax_amount
    or v_line_total<>v_doc.total_amount
    or v_doc.taxable_amount+v_doc.tax_amount<>v_doc.total_amount
    or v_subtotal<>v_doc.subtotal
    or v_subtotal-v_doc.discount_amount<>v_doc.taxable_amount then
    raise exception using errcode='23514',message='Purchase document totals do not reconcile';
  end if;

  if exists(
    select 1 from public.document_items di
    where di.business_id=p_business_id and di.document_id=p_document_id
      and (di.item_type<>'goods' or di.product_id is null or di.service_id is not null
        or di.quantity<=0 or di.unit_price<0 or di.discount_amount<0
        or di.discount_amount>round(di.quantity*di.unit_price)
        or di.tax_rate_snapshot<0 or di.tax_rate_snapshot>100)
  ) then
    raise exception using errcode='22023',message='Purchase document contains an invalid goods line';
  end if;

  -- Lock products in deterministic order to serialize stock posting.
  for v_item in
    select distinct di.product_id
    from public.document_items di
    where di.business_id=p_business_id and di.document_id=p_document_id
    order by di.product_id
  loop
    perform 1 from public.products p
    where p.business_id=p_business_id and p.id=v_item.product_id
      and p.is_active and p.track_inventory
    for update;
    if not found then
      raise exception using errcode='22023',message='Purchase product is missing, inactive, or does not track inventory';
    end if;
  end loop;

  select id into v_inventory_account_id from public.chart_of_accounts
  where business_id=p_business_id and code='1200' and account_class='asset'
    and is_active and allow_posting;
  select id into v_tax_account_id from public.chart_of_accounts
  where business_id=p_business_id and code='1300' and account_class='asset'
    and is_active and allow_posting;
  select id into v_payable_account_id from public.chart_of_accounts
  where business_id=p_business_id and code='2000' and account_class='liability'
    and is_active and allow_posting;
  if v_inventory_account_id is null or v_tax_account_id is null or v_payable_account_id is null then
    raise exception using errcode='55000',message='Purchase ledger accounts are not configured';
  end if;

  select fp.id into v_period_id
  from public.fiscal_periods fp
  where fp.business_id=p_business_id and v_doc.document_date between fp.date_from and fp.date_to
  order by fp.date_from desc limit 1;
  if v_period_id is not null and not exists(
    select 1 from public.fiscal_periods fp
    where fp.business_id=p_business_id and fp.id=v_period_id and fp.status in ('open','reopened')
  ) then
    raise exception using errcode='22023',message='Purchase date is in a closed fiscal period';
  end if;

  insert into public.journal_entries(
    business_id,entry_date,fiscal_period_id,source_type,source_id,description,
    status,idempotency_key,created_by
  ) values (
    p_business_id,v_doc.document_date,v_period_id,'document',p_document_id,
    coalesce(nullif(btrim(coalesce(v_doc.notes,'')),''),'ثبت فاکتور خرید'),
    'draft','purchase-post:'||p_idempotency_key,v_user
  ) returning id into v_journal_id;

  v_line_order:=0;
  for v_item in
    select di.* from public.document_items di
    where di.business_id=p_business_id and di.document_id=p_document_id
    order by di.sort_order,di.id
  loop
    v_line_order:=v_line_order+1;
    v_quantity:=v_item.quantity;
    v_line_base:=round(v_item.quantity*v_item.unit_price)-v_item.discount_amount;
    if v_line_order=v_item_count then
      v_allocated_header_discount:=v_header_discount-v_allocated_total;
    else
      v_allocated_header_discount:=case when v_base_total=0 then 0
        else floor(v_header_discount*v_line_base/v_base_total) end;
    end if;
    v_allocated_total:=v_allocated_total+v_allocated_header_discount;
    v_line_cost:=greatest(0,v_line_base-v_allocated_header_discount);
    v_line_tax:=round(v_line_cost*v_item.tax_rate_snapshot/100);
    if v_line_tax<>v_item.tax_amount or v_line_cost+v_line_tax<>v_item.line_total then
      raise exception using errcode='23514',message='Purchase line tax or total does not reconcile';
    end if;
    v_expected_tax:=v_expected_tax+v_line_tax;
    v_expected_total:=v_expected_total+v_line_cost+v_line_tax;
    v_unit_cost:=case when v_quantity=0 then 0 else round(v_line_cost/v_quantity) end;
    v_inventory_total:=v_inventory_total+v_line_cost;

    insert into public.stock_movements(
      business_id,product_id,warehouse_id,movement_type,quantity_delta,movement_date,
      document_id,document_item_id,idempotency_key,note,created_by
    ) values (
      p_business_id,v_item.product_id,v_doc.warehouse_id,'purchase',v_quantity,
      v_doc.document_date::timestamptz,p_document_id,v_item.id,
      'purchase:'||p_document_id::text||':'||v_item.id::text,
      nullif(btrim(coalesce(v_doc.notes,'')),''),v_user
    ) returning id into v_supplier_id;

    insert into public.inventory_cost_layers(
      business_id,product_id,warehouse_id,source_movement_id,quantity_in,quantity_remaining,unit_cost,acquired_at
    ) values (
      p_business_id,v_item.product_id,v_doc.warehouse_id,v_supplier_id,
      v_quantity,v_quantity,v_unit_cost,v_doc.document_date::timestamptz
    );

    insert into public.document_item_costs(
      business_id,document_item_id,unit_cost_snapshot,total_cost_snapshot,cost_source
    ) values (p_business_id,v_item.id,v_unit_cost,v_line_cost,'purchase_layer');

    insert into public.product_costs(
      business_id,product_id,purchase_cost,effective_from,source_type,source_id,created_by
    ) values (
      p_business_id,v_item.product_id,v_unit_cost,v_doc.document_date::timestamptz,'purchase',p_document_id,v_user
    );
  end loop;

  if v_inventory_total<>v_doc.taxable_amount or v_expected_tax<>v_doc.tax_amount
    or v_expected_total<>v_doc.total_amount then
    raise exception using errcode='23514',message='Purchase inventory, tax, or total does not reconcile';
  end if;

  insert into public.journal_lines(
    business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order
  ) values (
    p_business_id,v_journal_id,v_inventory_account_id,null,v_inventory_total,0,'ورود موجودی کالا',1
  );
  if v_doc.tax_amount>0 then
    insert into public.journal_lines(
      business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order
    ) values (
      p_business_id,v_journal_id,v_tax_account_id,null,v_doc.tax_amount,0,'مالیات خریدنی',2
    );
  end if;
  insert into public.journal_lines(
    business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order
  ) values (
    p_business_id,v_journal_id,v_payable_account_id,v_doc.contact_id,0,v_doc.total_amount,
    'بدهی به تأمین‌کننده',case when v_doc.tax_amount>0 then 3 else 2 end
  );

  update public.journal_entries
  set status='posted',posted_at=now(),posted_by=v_user,version=version+1
  where business_id=p_business_id and id=v_journal_id;

  insert into public.contact_ledger_entries(
    business_id,contact_id,entry_date,entry_type,debit,credit,document_id,description,source_legacy_id,created_by
  ) values (
    p_business_id,v_doc.contact_id,v_doc.document_date,'invoice_credit',0,v_doc.total_amount,
    p_document_id,coalesce(nullif(btrim(coalesce(v_doc.notes,'')),''),'فاکتور خرید'),
    'document_posting:'||p_document_id::text,v_user
  );

  insert into public.document_postings(
    business_id,document_id,journal_entry_id,idempotency_key,request_fingerprint,created_by
  ) values (p_business_id,p_document_id,v_journal_id,p_idempotency_key,v_fingerprint,v_user);

  update public.documents
  set status='posted',posted_at=now(),version=version+1
  where business_id=p_business_id and id=p_document_id;

  return v_journal_id;
end;
$$;

revoke all on function public.post_purchase_document(uuid,uuid,text) from public,anon;
grant execute on function public.post_purchase_document(uuid,uuid,text) to authenticated;

commit;
