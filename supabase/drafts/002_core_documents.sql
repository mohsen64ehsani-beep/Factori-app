-- 002: Tenant-safe contacts, warehouses, fiscal periods and draft documents.
-- DEVELOPMENT DRAFT ONLY. Depends on 001_identity_business_permissions.sql.
-- Posting, accounting journals, inventory movements and payment allocation are
-- intentionally excluded; this migration only creates validated drafts.
begin;

create table if not exists public.contacts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  contact_type text not null check(contact_type in ('customer','supplier','both')),
  name text not null check(length(btrim(name)) between 1 and 200),
  phone text,
  code text,
  address text,
  notes text,
  is_active boolean not null default true,
  legacy_id text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version bigint not null default 1 check(version>0),
  unique(business_id,id),
  unique(business_id,legacy_id)
);
create index if not exists contacts_business_name_idx on public.contacts(business_id,lower(name));
create index if not exists contacts_business_phone_idx on public.contacts(business_id,phone) where phone is not null;

create table if not exists public.warehouses (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null check(length(btrim(name)) between 1 and 120),
  code text,
  address text,
  is_default boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(business_id,id),
  unique(business_id,code)
);
create unique index if not exists warehouses_one_default_per_business
  on public.warehouses(business_id) where is_default and is_active;

create table if not exists public.fiscal_periods (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  title text not null check(length(btrim(title)) between 1 and 100),
  date_from date not null,
  date_to date not null,
  status text not null default 'open' check(status in ('open','closing','closed','reopened')),
  closed_at timestamptz,
  closed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(business_id,id),
  check(date_to>=date_from)
);
create index if not exists fiscal_periods_business_dates_idx
  on public.fiscal_periods(business_id,date_from,date_to);

create table if not exists public.documents (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  document_type text not null check(document_type in ('goods_sale','service_sale','purchase','service_purchase')),
  document_number text,
  contact_id uuid,
  warehouse_id uuid,
  fiscal_period_id uuid,
  document_date date not null default current_date,
  due_date date,
  status text not null default 'draft' check(status in ('draft','posted','voided')),
  subtotal numeric(20,0) not null default 0 check(subtotal>=0),
  discount_amount numeric(20,0) not null default 0 check(discount_amount>=0),
  taxable_amount numeric(20,0) not null default 0 check(taxable_amount>=0),
  tax_amount numeric(20,0) not null default 0 check(tax_amount>=0),
  total_amount numeric(20,0) not null default 0 check(total_amount>=0),
  notes text,
  source_document_id uuid,
  idempotency_key text,
  request_fingerprint text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  posted_at timestamptz,
  version bigint not null default 1 check(version>0),
  unique(business_id,id),
  unique(business_id,idempotency_key),
  foreign key(business_id,contact_id) references public.contacts(business_id,id),
  foreign key(business_id,warehouse_id) references public.warehouses(business_id,id),
  foreign key(business_id,fiscal_period_id) references public.fiscal_periods(business_id,id),
  foreign key(business_id,source_document_id) references public.documents(business_id,id),
  check(due_date is null or due_date>=document_date)
);
create index if not exists documents_business_date_idx on public.documents(business_id,document_date desc);
create index if not exists documents_business_contact_idx on public.documents(business_id,contact_id,document_date desc);
create index if not exists documents_business_status_idx on public.documents(business_id,status,document_date desc);

create table if not exists public.document_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  document_id uuid not null,
  item_type text not null check(item_type in ('goods','service')),
  product_id uuid,
  service_id uuid,
  description_snapshot text not null check(length(btrim(description_snapshot)) between 1 and 500),
  quantity numeric(20,4) not null check(quantity>0),
  unit_name_snapshot text,
  unit_price numeric(20,0) not null check(unit_price>=0),
  discount_amount numeric(20,0) not null default 0 check(discount_amount>=0),
  tax_rate_snapshot numeric(7,4) not null default 0 check(tax_rate_snapshot between 0 and 100),
  tax_amount numeric(20,0) not null default 0 check(tax_amount>=0),
  line_total numeric(20,0) not null default 0 check(line_total>=0),
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique(business_id,id),
  foreign key(business_id,document_id) references public.documents(business_id,id) on delete cascade,
  check(discount_amount<=round(quantity*unit_price))
);
create index if not exists document_items_document_idx on public.document_items(business_id,document_id,sort_order);

-- Updated-at triggers use the helper established in migration 001.
drop trigger if exists contacts_touch_updated_at on public.contacts;
create trigger contacts_touch_updated_at before update on public.contacts
for each row execute function private.touch_updated_at();
drop trigger if exists warehouses_touch_updated_at on public.warehouses;
create trigger warehouses_touch_updated_at before update on public.warehouses
for each row execute function private.touch_updated_at();
drop trigger if exists fiscal_periods_touch_updated_at on public.fiscal_periods;
create trigger fiscal_periods_touch_updated_at before update on public.fiscal_periods
for each row execute function private.touch_updated_at();
drop trigger if exists documents_touch_updated_at on public.documents;
create trigger documents_touch_updated_at before update on public.documents
for each row execute function private.touch_updated_at();

-- Draft creation is the only document write path exposed to authenticated clients.
create or replace function public.create_document_draft(
  p_business_id uuid,
  p_document_type text,
  p_contact_id uuid default null,
  p_warehouse_id uuid default null,
  p_fiscal_period_id uuid default null,
  p_document_date date default current_date,
  p_due_date date default null,
  p_notes text default null,
  p_discount_amount numeric default 0,
  p_tax_rate numeric default null,
  p_items jsonb default '[]'::jsonb,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user uuid:=auth.uid();
  v_doc_id uuid;
  v_permission text;
  v_item jsonb;
  v_qty numeric;
  v_price numeric;
  v_line_discount numeric;
  v_rate numeric;
  v_base numeric;
  v_base_total numeric:=0;
  v_subtotal numeric:=0;
  v_line_discounts numeric:=0;
  v_tax numeric:=0;
  v_allocated_header_discount numeric;
  v_tax_line numeric;
  v_total numeric;
  v_count integer:=0;
  v_item_count integer:=0;
  v_request_fingerprint text;
  v_existing_fingerprint text;
  v_allocated_total numeric:=0;
  v_header_discount numeric:=coalesce(p_discount_amount,0);
begin
  if v_user is null then raise exception using errcode='28000',message='Authentication required'; end if;
  if p_document_type is null or p_document_type not in ('goods_sale','service_sale','purchase','service_purchase') then
    raise exception using errcode='22023',message='Unsupported document type';
  end if;
  v_permission:=case when p_document_type in ('goods_sale','service_sale') then 'sales.create' else 'purchases.create' end;
  if not private.has_business_permission(p_business_id,v_permission) then
    raise exception using errcode='42501',message='Document creation is not permitted';
  end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 100 then
    raise exception using errcode='22023',message='Document must contain between 1 and 100 items';
  end if;
  if v_header_discount<0 or v_header_discount>999999999999999999 then
    raise exception using errcode='22023',message='Invalid document discount';
  end if;
  if p_tax_rate is not null and p_tax_rate not between 0 and 100 then
    raise exception using errcode='22023',message='Invalid tax rate';
  end if;
  if p_due_date is not null and p_due_date<coalesce(p_document_date,current_date) then
    raise exception using errcode='22023',message='Due date cannot precede document date';
  end if;

  if p_contact_id is not null and not exists (
    select 1 from public.contacts c
    where c.business_id=p_business_id and c.id=p_contact_id
      and c.is_active
      and (
        (p_document_type in ('goods_sale','service_sale') and c.contact_type in ('customer','both'))
        or (p_document_type in ('purchase','service_purchase') and c.contact_type in ('supplier','both'))
      )
  ) then
    raise exception using errcode='22023',message='Contact is inactive, missing or has an incompatible role';
  end if;

  if p_fiscal_period_id is not null and not exists (
    select 1 from public.fiscal_periods fp
    where fp.business_id=p_business_id and fp.id=p_fiscal_period_id
      and fp.status='open'
      and coalesce(p_document_date,current_date) between fp.date_from and fp.date_to
  ) then
    raise exception using errcode='22023',message='Fiscal period is closed or document date is outside the period';
  end if;
  if p_idempotency_key is not null and length(p_idempotency_key) not between 8 and 160 then
    raise exception using errcode='22023',message='Invalid idempotency key';
  end if;

  v_request_fingerprint:=md5(concat_ws('|',
    p_business_id::text,p_document_type,p_contact_id::text,p_warehouse_id::text,
    p_fiscal_period_id::text,coalesce(p_document_date,current_date)::text,p_due_date::text,
    coalesce(p_notes,''),v_header_discount::text,coalesce(p_tax_rate::text,'null'),p_items::text
  ));

  if p_idempotency_key is not null then
    select id,request_fingerprint into v_doc_id,v_existing_fingerprint
    from public.documents
    where business_id=p_business_id and idempotency_key=p_idempotency_key;
    if v_doc_id is not null then
      if v_existing_fingerprint is distinct from v_request_fingerprint then
        raise exception using errcode='23505',message='Idempotency key was already used with a different request';
      end if;
      return v_doc_id;
    end if;
  end if;

  -- Validate and total the submitted rows before inserting anything.
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_count:=v_count+1;
    if jsonb_typeof(v_item)<>'object' then raise exception using errcode='22023',message='Each item must be an object'; end if;
    v_qty:=coalesce((v_item->>'quantity')::numeric,0);
    v_price:=coalesce((v_item->>'unit_price')::numeric,0);
    v_line_discount:=coalesce((v_item->>'discount_amount')::numeric,0);
    v_rate:=coalesce(p_tax_rate,(v_item->>'tax_rate')::numeric,0);
    if v_qty<=0 or v_qty>1000000000 or v_price<0 or v_price>999999999999999999
      or v_line_discount<0 or v_line_discount>round(v_qty*v_price)
      or v_rate<0 or v_rate>100 then
      raise exception using errcode='22023',message='Invalid quantity, price, discount or tax rate';
    end if;
    if length(btrim(coalesce(v_item->>'description',''))) not between 1 and 500 then
      raise exception using errcode='22023',message='Item description is required';
    end if;
    if coalesce(v_item->>'item_type','goods') not in ('goods','service') then
      raise exception using errcode='22023',message='Invalid item type';
    end if;
    if (p_document_type in ('goods_sale','purchase') and coalesce(v_item->>'item_type','goods')<>'goods')
      or (p_document_type in ('service_sale','service_purchase') and coalesce(v_item->>'item_type','goods')<>'service') then
      raise exception using errcode='22023',message='Item type does not match document type';
    end if;
    v_base:=round(v_qty*v_price)-v_line_discount;
    v_subtotal:=v_subtotal+round(v_qty*v_price);
    v_line_discounts:=v_line_discounts+v_line_discount;
    v_base_total:=v_base_total+v_base;
  end loop;
  v_item_count:=v_count;
  if v_header_discount>v_base_total then raise exception using errcode='22023',message='Document discount exceeds taxable base'; end if;

  insert into public.documents(
    business_id,document_type,contact_id,warehouse_id,fiscal_period_id,
    document_date,due_date,discount_amount,subtotal,taxable_amount,notes,
    idempotency_key,request_fingerprint,created_by
  ) values (
    p_business_id,p_document_type,p_contact_id,p_warehouse_id,p_fiscal_period_id,
    coalesce(p_document_date,current_date),p_due_date,v_header_discount+v_line_discounts,
    v_subtotal,v_base_total-v_header_discount,nullif(btrim(coalesce(p_notes,'')),''),
    p_idempotency_key,v_request_fingerprint,v_user
  ) returning id into v_doc_id;

  v_count:=0;
  v_allocated_total:=0;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_count:=v_count+1;
    v_qty:=(v_item->>'quantity')::numeric;
    v_price:=(v_item->>'unit_price')::numeric;
    v_line_discount:=coalesce((v_item->>'discount_amount')::numeric,0);
    v_rate:=coalesce(p_tax_rate,(v_item->>'tax_rate')::numeric,0);
    v_base:=round(v_qty*v_price)-v_line_discount;
    if v_count=v_item_count then
      v_allocated_header_discount:=v_header_discount-v_allocated_total;
    else
      v_allocated_header_discount:=case when v_base_total=0 then 0
        else round(v_header_discount*v_base/v_base_total) end;
    end if;
    v_allocated_total:=v_allocated_total+v_allocated_header_discount;
    v_tax_line:=round(greatest(0,v_base-v_allocated_header_discount)*v_rate/100);
    v_tax:=v_tax+v_tax_line;
    insert into public.document_items(
      business_id,document_id,item_type,product_id,service_id,
      description_snapshot,quantity,unit_name_snapshot,unit_price,
      discount_amount,tax_rate_snapshot,tax_amount,line_total,sort_order
    ) values (
      p_business_id,v_doc_id,coalesce(v_item->>'item_type','goods'),
      nullif(v_item->>'product_id','')::uuid,nullif(v_item->>'service_id','')::uuid,
      btrim(v_item->>'description'),v_qty,nullif(v_item->>'unit_name',''),
      v_price,v_line_discount,v_rate,v_tax_line,
      greatest(0,round(v_qty*v_price)-v_line_discount-v_allocated_header_discount)+v_tax_line,
      v_count
    );
  end loop;
  v_total:=greatest(0,v_subtotal-v_line_discounts-v_header_discount)+v_tax;
  update public.documents set tax_amount=v_tax,total_amount=v_total
  where id=v_doc_id and business_id=p_business_id;
  return v_doc_id;
exception
  when unique_violation then
    if p_idempotency_key is not null then
      select id,request_fingerprint into v_doc_id,v_existing_fingerprint
      from public.documents
      where business_id=p_business_id and idempotency_key=p_idempotency_key;
      if v_doc_id is not null then
        if v_existing_fingerprint is distinct from v_request_fingerprint then
          raise exception using errcode='23505',message='Idempotency key was already used with a different request';
        end if;
        return v_doc_id;
      end if;
    end if;
    raise;
end;
$$;

alter table public.contacts enable row level security;
alter table public.warehouses enable row level security;
alter table public.fiscal_periods enable row level security;
alter table public.documents enable row level security;
alter table public.document_items enable row level security;

drop policy if exists contacts_read on public.contacts;
create policy contacts_read on public.contacts for select to authenticated
using(private.has_business_permission(business_id,'contacts.read'));
drop policy if exists warehouses_read on public.warehouses;
create policy warehouses_read on public.warehouses for select to authenticated
using(private.has_business_permission(business_id,'inventory.read'));
drop policy if exists fiscal_periods_read on public.fiscal_periods;
create policy fiscal_periods_read on public.fiscal_periods for select to authenticated
using(private.has_business_permission(business_id,'business.read'));
drop policy if exists documents_read on public.documents;
create policy documents_read on public.documents for select to authenticated
using(
  (document_type in ('goods_sale','service_sale') and private.has_business_permission(business_id,'sales.read'))
  or (document_type in ('purchase','service_purchase') and private.has_business_permission(business_id,'purchases.read'))
);
drop policy if exists document_items_read on public.document_items;
create policy document_items_read on public.document_items for select to authenticated
using(exists(
  select 1 from public.documents d where d.business_id=document_items.business_id
    and d.id=document_items.document_id
    and ((d.document_type in ('goods_sale','service_sale') and private.has_business_permission(d.business_id,'sales.read'))
      or (d.document_type in ('purchase','service_purchase') and private.has_business_permission(d.business_id,'purchases.read')))
));

revoke all on public.contacts,public.warehouses,public.fiscal_periods,public.documents,public.document_items from public,anon;
grant select on public.contacts,public.warehouses,public.fiscal_periods,public.documents,public.document_items to authenticated;
revoke all on function public.create_document_draft(uuid,text,uuid,uuid,uuid,date,date,text,numeric,numeric,jsonb,text) from public,anon,authenticated;
grant execute on function public.create_document_draft(uuid,text,uuid,uuid,uuid,date,date,text,numeric,numeric,jsonb,text) to authenticated;

commit;
