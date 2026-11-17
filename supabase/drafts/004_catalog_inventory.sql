-- 004: Product/service catalog and append-only inventory movement foundation.
-- DEVELOPMENT DRAFT ONLY. Depends on migrations 001-003.
-- No stock-changing RPC is exposed in this schema-only draft.
begin;

create table if not exists public.product_categories (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 name text not null check(length(btrim(name)) between 1 and 120),
 parent_id uuid,
 legacy_id text,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(business_id,id),
 unique(business_id,name),
 unique(business_id,legacy_id),
 foreign key(business_id,parent_id) references public.product_categories(business_id,id)
);
create index if not exists product_categories_parent_idx on public.product_categories(business_id,parent_id);

create table if not exists public.products (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 category_id uuid,
 name text not null check(length(btrim(name)) between 1 and 200),
 sku text,
 barcode text,
 unit_name text not null default 'عدد',
 sale_price numeric(20,0) not null default 0 check(sale_price>=0),
 track_inventory boolean not null default true,
 minimum_stock numeric(20,4) not null default 0 check(minimum_stock>=0),
 is_active boolean not null default true,
 legacy_id text,
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 version bigint not null default 1 check(version>0),
 unique(business_id,id),
 unique(business_id,legacy_id),
 foreign key(business_id,category_id) references public.product_categories(business_id,id)
);
create unique index if not exists products_business_sku_unique
 on public.products(business_id,sku) where sku is not null and sku<>'';
create unique index if not exists products_business_barcode_unique
 on public.products(business_id,barcode) where barcode is not null and barcode<>'';
create index if not exists products_business_name_idx on public.products(business_id,lower(name));

create table if not exists public.product_costs (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null,
 product_id uuid not null,
 purchase_cost numeric(20,0) not null default 0 check(purchase_cost>=0),
 effective_from timestamptz not null default now(),
 source_type text not null default 'manual' check(source_type in ('manual','purchase','opening','adjustment')),
 source_id uuid,
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 foreign key(business_id,product_id) references public.products(business_id,id),
 unique(business_id,id)
);
create index if not exists product_costs_product_effective_idx
 on public.product_costs(business_id,product_id,effective_from desc);

create table if not exists public.services (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 name text not null check(length(btrim(name)) between 1 and 200),
 description text,
 sale_price numeric(20,0) not null default 0 check(sale_price>=0),
 is_active boolean not null default true,
 legacy_id text,
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 version bigint not null default 1 check(version>0),
 unique(business_id,id),
 unique(business_id,legacy_id)
);
create index if not exists services_business_name_idx on public.services(business_id,lower(name));

-- Attach normalized catalog references after the catalog tables exist.
do $$
begin
 if not exists(select 1 from pg_constraint where conname='document_items_product_tenant_fk') then
  alter table public.document_items add constraint document_items_product_tenant_fk
   foreign key(business_id,product_id) references public.products(business_id,id);
 end if;
 if not exists(select 1 from pg_constraint where conname='document_items_service_tenant_fk') then
  alter table public.document_items add constraint document_items_service_tenant_fk
   foreign key(business_id,service_id) references public.services(business_id,id);
 end if;
 if not exists(select 1 from pg_constraint where conname='document_items_catalog_type_check') then
  alter table public.document_items add constraint document_items_catalog_type_check
   check(
    (item_type='goods' and service_id is null)
    or (item_type='service' and product_id is null)
   );
 end if;
end $;

create table if not exists public.document_item_costs (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null,
 document_item_id uuid not null,
 unit_cost_snapshot numeric(20,0) not null default 0 check(unit_cost_snapshot>=0),
 total_cost_snapshot numeric(20,0) not null default 0 check(total_cost_snapshot>=0),
 cost_source text not null check(cost_source in ('sale_snapshot','purchase_layer','weighted_average','fifo','manual','legacy')),
 created_at timestamptz not null default now(),
 foreign key(business_id,document_item_id) references public.document_items(business_id,id) on delete cascade,
 unique(business_id,document_item_id)
);
create index if not exists document_item_costs_business_idx on public.document_item_costs(business_id);

create table if not exists public.stock_movements (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null,
 product_id uuid not null,
 warehouse_id uuid not null,
 movement_type text not null check(movement_type in
  ('opening','purchase','sale','sales_return','purchase_return','wastage','adjustment','transfer_in','transfer_out')),
 quantity_delta numeric(20,4) not null check(quantity_delta<>0),
 movement_date timestamptz not null default now(),
 document_id uuid,
 document_item_id uuid,
 transfer_id uuid,
 idempotency_key text,
 source_legacy_id text,
 note text,
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 foreign key(business_id,product_id) references public.products(business_id,id),
 foreign key(business_id,warehouse_id) references public.warehouses(business_id,id),
 foreign key(business_id,document_id) references public.documents(business_id,id),
 foreign key(business_id,document_item_id) references public.document_items(business_id,id),
 unique(business_id,idempotency_key),
 unique(business_id,source_legacy_id)
);
create index if not exists stock_movements_balance_idx
 on public.stock_movements(business_id,product_id,warehouse_id,movement_date,id);
create index if not exists stock_movements_document_idx
 on public.stock_movements(business_id,document_id);

create table if not exists public.stock_transfers (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 transfer_number text,
 from_warehouse_id uuid not null,
 to_warehouse_id uuid not null,
 transfer_date date not null,
 status text not null default 'draft' check(status in ('draft','posted','voided')),
 note text,
 idempotency_key text,
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 version bigint not null default 1 check(version>0),
 unique(business_id,id),
 unique(business_id,transfer_number),
 unique(business_id,idempotency_key),
 foreign key(business_id,from_warehouse_id) references public.warehouses(business_id,id),
 foreign key(business_id,to_warehouse_id) references public.warehouses(business_id,id),
 check(from_warehouse_id<>to_warehouse_id)
);
create table if not exists public.stock_transfer_items (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null,
 transfer_id uuid not null,
 product_id uuid not null,
 quantity numeric(20,4) not null check(quantity>0),
 line_order integer not null default 0,
 foreign key(business_id,transfer_id) references public.stock_transfers(business_id,id) on delete cascade,
 foreign key(business_id,product_id) references public.products(business_id,id),
 unique(business_id,id)
);
create index if not exists stock_transfer_items_transfer_idx on public.stock_transfer_items(business_id,transfer_id,line_order);

create table if not exists public.inventory_cost_layers (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null,
 product_id uuid not null,
 warehouse_id uuid not null,
 source_movement_id uuid not null,
 quantity_in numeric(20,4) not null check(quantity_in>0),
 quantity_remaining numeric(20,4) not null check(quantity_remaining>=0 and quantity_remaining<=quantity_in),
 unit_cost numeric(20,0) not null check(unit_cost>=0),
 acquired_at timestamptz not null default now(),
 foreign key(business_id,product_id) references public.products(business_id,id),
 foreign key(business_id,warehouse_id) references public.warehouses(business_id,id),
 foreign key(business_id,source_movement_id) references public.stock_movements(business_id,id),
 unique(business_id,id)
);
create index if not exists inventory_cost_layers_fifo_idx
 on public.inventory_cost_layers(business_id,product_id,warehouse_id,acquired_at,id)
 where quantity_remaining>0;

create table if not exists public.inventory_cost_allocations (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null,
 layer_id uuid not null,
 stock_movement_id uuid not null,
 quantity numeric(20,4) not null check(quantity>0),
 unit_cost numeric(20,0) not null check(unit_cost>=0),
 total_cost numeric(20,0) not null check(total_cost>=0),
 created_at timestamptz not null default now(),
 foreign key(business_id,layer_id) references public.inventory_cost_layers(business_id,id),
 foreign key(business_id,stock_movement_id) references public.stock_movements(business_id,id),
 unique(business_id,id)
);
create index if not exists inventory_cost_allocations_movement_idx
 on public.inventory_cost_allocations(business_id,stock_movement_id);

-- updated_at triggers.
drop trigger if exists product_categories_touch_updated_at on public.product_categories;
create trigger product_categories_touch_updated_at before update on public.product_categories
for each row execute function private.touch_updated_at();
drop trigger if exists products_touch_updated_at on public.products;
create trigger products_touch_updated_at before update on public.products
for each row execute function private.touch_updated_at();
drop trigger if exists services_touch_updated_at on public.services;
create trigger services_touch_updated_at before update on public.services
for each row execute function private.touch_updated_at();
drop trigger if exists stock_transfers_touch_updated_at on public.stock_transfers;
create trigger stock_transfers_touch_updated_at before update on public.stock_transfers
for each row execute function private.touch_updated_at();

alter table public.product_categories enable row level security;
alter table public.products enable row level security;
alter table public.product_costs enable row level security;
alter table public.services enable row level security;
alter table public.document_item_costs enable row level security;
alter table public.stock_movements enable row level security;
alter table public.stock_transfers enable row level security;
alter table public.stock_transfer_items enable row level security;
alter table public.inventory_cost_layers enable row level security;
alter table public.inventory_cost_allocations enable row level security;

drop policy if exists product_categories_read on public.product_categories;
create policy product_categories_read on public.product_categories for select to authenticated
 using(private.has_business_permission(business_id,'catalog.read'));
drop policy if exists products_read on public.products;
create policy products_read on public.products for select to authenticated
 using(private.has_business_permission(business_id,'catalog.read'));
drop policy if exists product_costs_read on public.product_costs;
create policy product_costs_read on public.product_costs for select to authenticated
 using(private.has_business_permission(business_id,'catalog.cost.read'));
drop policy if exists services_read on public.services;
create policy services_read on public.services for select to authenticated
 using(private.has_business_permission(business_id,'catalog.read'));
drop policy if exists document_item_costs_read on public.document_item_costs;
create policy document_item_costs_read on public.document_item_costs for select to authenticated
 using(private.has_business_permission(business_id,'catalog.cost.read'));
drop policy if exists stock_movements_read on public.stock_movements;
create policy stock_movements_read on public.stock_movements for select to authenticated
 using(private.has_business_permission(business_id,'inventory.read'));
drop policy if exists stock_transfers_read on public.stock_transfers;
create policy stock_transfers_read on public.stock_transfers for select to authenticated
 using(private.has_business_permission(business_id,'inventory.read'));
drop policy if exists stock_transfer_items_read on public.stock_transfer_items;
create policy stock_transfer_items_read on public.stock_transfer_items for select to authenticated
 using(private.has_business_permission(business_id,'inventory.read'));
drop policy if exists inventory_cost_layers_read on public.inventory_cost_layers;
create policy inventory_cost_layers_read on public.inventory_cost_layers for select to authenticated
 using(private.has_business_permission(business_id,'catalog.cost.read'));
drop policy if exists inventory_cost_allocations_read on public.inventory_cost_allocations;
create policy inventory_cost_allocations_read on public.inventory_cost_allocations for select to authenticated
 using(private.has_business_permission(business_id,'catalog.cost.read'));

revoke all on public.product_categories,public.products,public.product_costs,public.services,
 public.document_item_costs,public.stock_movements,public.stock_transfers,public.stock_transfer_items,
 public.inventory_cost_layers,public.inventory_cost_allocations from public,anon;
grant select on public.product_categories,public.products,public.product_costs,public.services,
 public.document_item_costs,public.stock_movements,public.stock_transfers,public.stock_transfer_items,
 public.inventory_cost_layers,public.inventory_cost_allocations to authenticated;

commit;
