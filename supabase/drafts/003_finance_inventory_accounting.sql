-- DRAFT ONLY. Depends on 001 and 002. Do not apply to production.
begin;

create table public.financial_accounts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  name text not null,
  account_type text not null check (account_type in ('cash','bank','clearing','other')),
  currency_code text not null default 'IRR',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id,id)
);

create table public.financial_transactions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  transaction_type text not null check (transaction_type in ('receipt','payment','supplier_payment','creditor_payment','refund','opening','adjustment','transfer_in','transfer_out')),
  contact_id uuid,
  financial_account_id uuid,
  amount bigint not null check (amount > 0),
  currency_code text not null default 'IRR',
  transaction_date date not null,
  payment_method text not null check (payment_method in ('cash','bank','cheque','card','transfer','other')),
  status text not null default 'posted' check (status in ('draft','posted','reversed','voided')),
  reference_number text,
  description text,
  source_type text,
  source_id uuid,
  idempotency_key uuid not null,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (business_id,id),
  unique (business_id,idempotency_key),
  foreign key (business_id,contact_id) references public.contacts(business_id,id) on delete restrict,
  foreign key (business_id,financial_account_id) references public.financial_accounts(business_id,id) on delete restrict,
  check ((payment_method='cheque') or financial_account_id is not null or status='draft')
);
create index financial_transactions_date_idx on public.financial_transactions(business_id,transaction_date desc);
create index financial_transactions_contact_idx on public.financial_transactions(business_id,contact_id,transaction_date desc);

create table public.transaction_allocations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  transaction_id uuid not null,
  document_id uuid not null,
  allocated_amount bigint not null check (allocated_amount > 0),
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles(id),
  unique (business_id,id),
  foreign key (business_id,transaction_id) references public.financial_transactions(business_id,id) on delete restrict,
  foreign key (business_id,document_id) references public.documents(business_id,id) on delete restrict
);
create index transaction_allocations_tx_idx on public.transaction_allocations(business_id,transaction_id);
create index transaction_allocations_doc_idx on public.transaction_allocations(business_id,document_id);

create table public.business_bank_details (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  title text,
  bank_name text,
  account_holder text,
  account_number text,
  card_number text,
  iban text,
  is_default boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (business_id,id)
);


create table public.opening_balances (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  contact_id uuid,
  financial_account_id uuid,
  opening_type text not null check (opening_type in ('customer_receivable','supplier_payable','cash','bank','equity','other')),
  debit_amount bigint not null default 0 check (debit_amount >= 0),
  credit_amount bigint not null default 0 check (credit_amount >= 0),
  effective_date date not null,
  note text,
  legacy_collection text,
  legacy_id text,
  created_at timestamptz not null default now(),
  foreign key (business_id,contact_id) references public.contacts(business_id,id) on delete restrict,
  foreign key (business_id,financial_account_id) references public.financial_accounts(business_id,id) on delete restrict,
  check ((debit_amount > 0 and credit_amount = 0) or (credit_amount > 0 and debit_amount = 0))
);

create table public.transaction_allocation_reversals (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  allocation_id uuid not null,
  reversed_amount bigint not null check (reversed_amount > 0),
  reason text not null,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  foreign key (business_id,allocation_id) references public.transaction_allocations(business_id,id) on delete restrict
);
create index transaction_allocation_reversals_idx on public.transaction_allocation_reversals(business_id,allocation_id);

create unique index business_bank_details_one_default_uidx on public.business_bank_details(business_id) where is_default;

create table public.cheques (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  direction text not null check (direction in ('received','issued')),
  contact_id uuid,
  financial_transaction_id uuid,
  cheque_number text,
  sayad_id text,
  bank_name text,
  branch_name text,
  account_number text,
  account_holder text,
  amount bigint not null check (amount > 0),
  currency_code text not null default 'IRR',
  issue_date date,
  due_date date,
  status text not null default 'pending' check (status in ('pending','deposited','collected','returned','cancelled','assigned')),
  image_path text,
  created_at timestamptz not null default now(),
  unique (business_id,id),
  foreign key (business_id,contact_id) references public.contacts(business_id,id) on delete restrict,
  foreign key (business_id,financial_transaction_id) references public.financial_transactions(business_id,id) on delete restrict
);
create index cheques_due_idx on public.cheques(business_id,status,due_date);
create index cheques_contact_idx on public.cheques(business_id,contact_id);

create unique index cheques_transaction_uidx on public.cheques(business_id,financial_transaction_id) where financial_transaction_id is not null;

create table public.cheque_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  cheque_id uuid not null,
  event_type text not null,
  previous_status text,
  new_status text,
  event_date timestamptz not null default now(),
  note text,
  performed_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  foreign key (business_id,cheque_id) references public.cheques(business_id,id) on delete restrict
);
create index cheque_events_timeline_idx on public.cheque_events(business_id,cheque_id,created_at);

create table public.cheque_assignments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  source_cheque_id uuid not null,
  target_contact_id uuid not null,
  assigned_amount bigint not null check (assigned_amount > 0),
  assignment_date date not null,
  status text not null default 'posted' check (status in ('draft','posted','reversed')),
  note text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  foreign key (business_id,source_cheque_id) references public.cheques(business_id,id) on delete restrict,
  foreign key (business_id,target_contact_id) references public.contacts(business_id,id) on delete restrict
);

create table public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  product_id uuid not null,
  warehouse_id uuid not null,
  movement_type text not null check (movement_type in ('opening','purchase','sale','sales_return','purchase_return','wastage','transfer_in','transfer_out','adjustment','reversal')),
  quantity_delta numeric(20,4) not null check (quantity_delta <> 0),
  source_type text,
  source_id uuid,
  movement_date timestamptz not null,
  reversal_of uuid,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  foreign key (business_id,product_id) references public.products(business_id,id) on delete restrict,
  foreign key (business_id,warehouse_id) references public.warehouses(business_id,id) on delete restrict,
  foreign key (business_id,reversal_of) references public.stock_movements(business_id,id) on delete restrict,
  unique (business_id,id)
);
create index stock_movements_lookup_idx on public.stock_movements(business_id,product_id,warehouse_id,movement_date);
create unique index stock_movement_single_reversal_uidx on public.stock_movements(business_id,reversal_of) where reversal_of is not null;

create table public.warehouse_stock_balances (
  business_id uuid not null,
  warehouse_id uuid not null,
  product_id uuid not null,
  quantity_on_hand numeric(20,4) not null default 0,
  updated_at timestamptz not null default now(),
  primary key (business_id,warehouse_id,product_id),
  foreign key (business_id,warehouse_id) references public.warehouses(business_id,id) on delete restrict,
  foreign key (business_id,product_id) references public.products(business_id,id) on delete restrict
);

create table public.stock_transfers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  from_warehouse_id uuid not null,
  to_warehouse_id uuid not null,
  transfer_date timestamptz not null,
  status text not null default 'draft' check (status in ('draft','posted','reversed')),
  note text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (business_id,id),
  foreign key (business_id,from_warehouse_id) references public.warehouses(business_id,id) on delete restrict,
  foreign key (business_id,to_warehouse_id) references public.warehouses(business_id,id) on delete restrict,
  check (from_warehouse_id <> to_warehouse_id)
);

create table public.stock_transfer_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  transfer_id uuid not null,
  product_id uuid not null,
  quantity numeric(20,4) not null check (quantity > 0),
  created_at timestamptz not null default now(),
  foreign key (business_id,transfer_id) references public.stock_transfers(business_id,id) on delete restrict,
  foreign key (business_id,product_id) references public.products(business_id,id) on delete restrict
);

create table public.inventory_opening_balances (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  product_id uuid not null,
  warehouse_id uuid not null,
  quantity numeric(20,4) not null check (quantity >= 0),
  source_migration_batch_id uuid,
  created_at timestamptz not null default now(),
  unique (business_id,id),
  foreign key (business_id,product_id) references public.products(business_id,id) on delete restrict,
  foreign key (business_id,warehouse_id) references public.warehouses(business_id,id) on delete restrict
);


create table private.stock_movement_costs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  movement_id uuid not null,
  unit_cost bigint not null default 0 check (unit_cost >= 0),
  total_cost bigint not null default 0 check (total_cost >= 0),
  created_at timestamptz not null default now(),
  unique (business_id,movement_id),
  foreign key (business_id,movement_id) references public.stock_movements(business_id,id) on delete restrict
);

create table private.warehouse_stock_cost_balances (
  business_id uuid not null,
  warehouse_id uuid not null,
  product_id uuid not null,
  inventory_value bigint not null default 0,
  average_unit_cost bigint not null default 0,
  updated_at timestamptz not null default now(),
  primary key (business_id,warehouse_id,product_id),
  foreign key (business_id,warehouse_id,product_id)
    references public.warehouse_stock_balances(business_id,warehouse_id,product_id) on delete restrict
);

create table private.inventory_opening_costs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  opening_balance_id uuid not null,
  unit_cost bigint not null check (unit_cost >= 0),
  total_cost bigint not null check (total_cost >= 0),
  created_at timestamptz not null default now(),
  unique (business_id,opening_balance_id),
  foreign key (business_id,opening_balance_id)
    references public.inventory_opening_balances(business_id,id) on delete restrict
);

create table private.inventory_cost_layers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  product_id uuid not null,
  warehouse_id uuid not null,
  source_movement_id uuid not null,
  quantity_received numeric(20,4) not null check (quantity_received > 0),
  quantity_remaining numeric(20,4) not null check (quantity_remaining >= 0),
  unit_cost bigint not null check (unit_cost >= 0),
  created_at timestamptz not null default now(),
  unique (business_id,id),
  foreign key (business_id,product_id) references public.products(business_id,id) on delete restrict,
  foreign key (business_id,warehouse_id) references public.warehouses(business_id,id) on delete restrict,
  foreign key (business_id,source_movement_id) references public.stock_movements(business_id,id) on delete restrict,
  check (quantity_remaining <= quantity_received)
);

create table private.inventory_cost_allocations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  cost_layer_id uuid not null,
  outbound_movement_id uuid not null,
  quantity numeric(20,4) not null check (quantity > 0),
  allocated_cost bigint not null check (allocated_cost >= 0),
  created_at timestamptz not null default now(),
  foreign key (business_id,cost_layer_id) references private.inventory_cost_layers(business_id,id) on delete restrict,
  foreign key (business_id,outbound_movement_id) references public.stock_movements(business_id,id) on delete restrict
);

create table public.chart_of_accounts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  code text not null,
  name text not null,
  account_group text not null check (account_group in ('asset','liability','equity','revenue','expense')),
  parent_id uuid,
  normal_balance text not null check (normal_balance in ('debit','credit')),
  is_postable boolean not null default true,
  is_active boolean not null default true,
  unique (business_id,id),
  unique (business_id,code),
  foreign key (business_id,parent_id) references public.chart_of_accounts(business_id,id) on delete restrict
);

create table public.journal_entries (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  entry_number text not null,
  entry_date date not null,
  fiscal_period_id uuid,
  description text,
  source_type text,
  source_id uuid,
  status text not null default 'draft' check (status in ('draft','posted','reversed')),
  reversal_of uuid,
  posted_by uuid references public.profiles(id),
  posted_at timestamptz,
  created_at timestamptz not null default now(),
  unique (business_id,id),
  unique (business_id,entry_number),
  foreign key (business_id,fiscal_period_id) references public.fiscal_periods(business_id,id) on delete restrict,
  foreign key (business_id,reversal_of) references public.journal_entries(business_id,id) on delete restrict,
  check ((status <> 'posted') or posted_at is not null)
);
create unique index journal_entries_source_uidx on public.journal_entries(business_id,source_type,source_id) where source_type is not null and source_id is not null;

create table public.journal_lines (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  journal_entry_id uuid not null,
  account_id uuid not null,
  contact_id uuid,
  debit bigint not null default 0 check (debit >= 0),
  credit bigint not null default 0 check (credit >= 0),
  description text,
  created_at timestamptz not null default now(),
  foreign key (business_id,journal_entry_id) references public.journal_entries(business_id,id) on delete restrict,
  foreign key (business_id,account_id) references public.chart_of_accounts(business_id,id) on delete restrict,
  foreign key (business_id,contact_id) references public.contacts(business_id,id) on delete restrict,
  check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0))
);
create index journal_lines_account_idx on public.journal_lines(business_id,account_id);
create index journal_lines_entry_idx on public.journal_lines(business_id,journal_entry_id);

create view public.contact_ledger_entries
with (security_invoker=true)
as
select jl.business_id,jl.contact_id,je.entry_date,jl.debit,jl.credit,
       je.source_type,je.source_id,je.id as journal_entry_id
from public.journal_lines jl
join public.journal_entries je
  on je.business_id=jl.business_id and je.id=jl.journal_entry_id
where je.status='posted' and jl.contact_id is not null;

commit;
