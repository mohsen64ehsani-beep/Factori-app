-- DRAFT ONLY. Depends on 001_identity_permissions.sql. Do not apply to production.
begin;

create table public.contacts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  display_name text not null,
  contact_type text not null default 'person' check (contact_type in ('person','company')),
  phone text,
  email text,
  national_id text,
  notes text,
  is_customer boolean not null default false,
  is_supplier boolean not null default false,
  is_active boolean not null default true,
  legacy_collection text,
  legacy_id text,
  idempotency_key uuid,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version bigint not null default 1,
  unique (business_id,id),
  check (is_customer or is_supplier)
);
create index contacts_business_name_idx on public.contacts(business_id,display_name);
create index contacts_business_phone_idx on public.contacts(business_id,phone) where phone is not null;

create table public.contact_addresses (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  contact_id uuid not null,
  title text,
  address text not null,
  postal_code text,
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  foreign key (business_id,contact_id) references public.contacts(business_id,id) on delete restrict,
  unique (business_id,id)
);

create table public.product_categories (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  parent_id uuid,
  name text not null,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (business_id,id),
  foreign key (business_id,parent_id) references public.product_categories(business_id,id) on delete restrict
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  category_id uuid,
  name text not null,
  sku text,
  barcode text,
  unit_name text not null default 'عدد',
  sale_price bigint not null default 0 check (sale_price >= 0),
  minimum_stock numeric(20,4) not null default 0 check (minimum_stock >= 0),
  is_active boolean not null default true,
  legacy_collection text,
  legacy_id text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version bigint not null default 1,
  unique (business_id,id),
  foreign key (business_id,category_id) references public.product_categories(business_id,id) on delete restrict
);
create index products_business_name_idx on public.products(business_id,name);
create unique index products_business_sku_uidx on public.products(business_id,sku) where sku is not null and sku <> '';

create table private.product_costs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  product_id uuid not null,
  last_purchase_cost bigint not null default 0 check (last_purchase_cost >= 0),
  average_cost bigint not null default 0 check (average_cost >= 0),
  costing_method text not null default 'weighted_average' check (costing_method in ('weighted_average','fifo')),
  effective_at timestamptz not null default now(),
  foreign key (business_id,product_id) references public.products(business_id,id) on delete restrict,
  unique (business_id,product_id)
);

create table public.services (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  name text not null,
  description text,
  default_price bigint not null default 0 check (default_price >= 0),
  is_active boolean not null default true,
  legacy_collection text,
  legacy_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id,id)
);

create table public.warehouses (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  name text not null,
  code text,
  address text,
  is_default boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (business_id,id),
  unique (business_id,code)
);

create table public.fiscal_periods (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  title text not null,
  start_date date not null,
  end_date date not null,
  status text not null default 'open' check (status in ('open','closing','closed','reopened')),
  closed_at timestamptz,
  closed_by uuid references public.profiles(id),
  reopened_at timestamptz,
  reopened_by uuid references public.profiles(id),
  reopen_reason text,
  check (end_date >= start_date),
  unique (business_id,id)
);
create index fiscal_periods_range_idx on public.fiscal_periods(business_id,start_date,end_date);

create table public.invoice_number_sequences (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  document_type text not null,
  fiscal_period_id uuid,
  prefix text not null default '',
  next_number bigint not null default 1 check (next_number > 0),
  number_padding smallint not null default 0 check (number_padding between 0 and 18),
  reset_policy text not null default 'never' check (reset_policy in ('never','fiscal_period','calendar_year')),
  unique nulls not distinct (business_id,document_type,fiscal_period_id),
  foreign key (business_id,fiscal_period_id) references public.fiscal_periods(business_id,id) on delete restrict
);

create table public.documents (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  document_type text not null check (document_type in ('sale','service_sale','purchase','sales_return','purchase_return','expense','other_income','wastage','opening_balance','adjustment')),
  document_number text not null,
  fiscal_period_id uuid,
  contact_id uuid,
  warehouse_id uuid,
  document_date date not null,
  due_date date,
  currency_code text not null default 'IRR',
  status text not null default 'draft' check (status in ('draft','posted','voided')),
  subtotal bigint not null default 0 check (subtotal >= 0),
  discount_amount bigint not null default 0 check (discount_amount >= 0),
  taxable_amount bigint not null default 0 check (taxable_amount >= 0),
  tax_amount bigint not null default 0 check (tax_amount >= 0),
  total_amount bigint not null default 0 check (total_amount >= 0),
  notes text,
  source_document_id uuid,
  posted_at timestamptz,
  legacy_collection text,
  legacy_id text,
  idempotency_key uuid,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version bigint not null default 1,
  unique (business_id,id),
  unique nulls not distinct (business_id,document_type,fiscal_period_id,document_number),
  foreign key (business_id,contact_id) references public.contacts(business_id,id) on delete restrict,
  foreign key (business_id,warehouse_id) references public.warehouses(business_id,id) on delete restrict,
  foreign key (business_id,fiscal_period_id) references public.fiscal_periods(business_id,id) on delete restrict,
  foreign key (business_id,source_document_id) references public.documents(business_id,id) on delete restrict,
  check (due_date is null or due_date >= document_date),
  check ((status <> 'posted') or posted_at is not null)
);
create unique index documents_idempotency_uidx on public.documents(business_id,idempotency_key) where idempotency_key is not null;
create index documents_business_date_idx on public.documents(business_id,document_date desc);
create index documents_business_type_status_idx on public.documents(business_id,document_type,status);

create table public.document_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  document_id uuid not null,
  product_id uuid,
  service_id uuid,
  item_type text not null check (item_type in ('product','service','free_text')),
  description_snapshot text not null,
  quantity numeric(20,4) not null check (quantity > 0),
  unit_name_snapshot text not null,
  unit_price bigint not null check (unit_price >= 0),
  discount_amount bigint not null default 0 check (discount_amount >= 0),
  tax_rate_snapshot numeric(8,4) not null default 0 check (tax_rate_snapshot >= 0),
  tax_amount bigint not null default 0 check (tax_amount >= 0),
  line_total bigint not null check (line_total >= 0),
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (business_id,id),
  foreign key (business_id,document_id) references public.documents(business_id,id) on delete restrict,
  foreign key (business_id,product_id) references public.products(business_id,id) on delete restrict,
  foreign key (business_id,service_id) references public.services(business_id,id) on delete restrict,
  check (
    (item_type='product' and product_id is not null and service_id is null) or
    (item_type='service' and service_id is not null and product_id is null) or
    (item_type='free_text' and product_id is null and service_id is null)
  )
);
create index document_items_document_idx on public.document_items(business_id,document_id,sort_order);

-- Costs are intentionally placed in a separate private schema/table, not in the API-visible line table.
create table private.document_item_costs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  document_item_id uuid not null,
  unit_cost_snapshot bigint not null default 0 check (unit_cost_snapshot >= 0),
  total_cost_snapshot bigint not null default 0 check (total_cost_snapshot >= 0),
  cost_source text not null default 'snapshot',
  created_at timestamptz not null default now(),
  unique (business_id,document_item_id),
  foreign key (business_id,document_item_id) references public.document_items(business_id,id) on delete restrict
);

create table public.document_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  document_id uuid not null,
  event_type text not null,
  old_status text,
  new_status text,
  event_payload jsonb not null default '{}'::jsonb,
  performed_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  foreign key (business_id,document_id) references public.documents(business_id,id) on delete restrict
);
create index document_events_timeline_idx on public.document_events(business_id,document_id,created_at);

commit;
