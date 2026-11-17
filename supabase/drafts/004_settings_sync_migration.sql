-- DRAFT ONLY. Depends on 001-003. Do not apply to production.
begin;

create table public.business_settings (
  business_id uuid primary key references public.businesses(id) on delete restrict,
  currency_code text not null default 'IRR',
  currency_scale smallint not null default 1 check (currency_scale > 0),
  display_currency_unit text not null default 'IRR' check (display_currency_unit in ('IRR','IRT')),
  timezone text not null default 'Asia/Tehran',
  date_calendar text not null default 'jalali' check (date_calendar in ('jalali','gregorian')),
  costing_method text not null default 'weighted_average' check (costing_method in ('weighted_average','fifo')),
  tax_enabled boolean not null default false,
  default_tax_rate numeric(8,4) not null default 0 check (default_tax_rate >= 0),
  invoice_prefix text not null default '',
  service_cost_mode text not null default 'row' check (service_cost_mode in ('row','total')),
  negative_stock_allowed boolean not null default false,
  fiscal_year_start text,
  settings_json jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table public.business_invoice_settings (
  business_id uuid primary key references public.businesses(id) on delete restrict,
  template_code text,
  accent_color text,
  show_logo boolean not null default true,
  footer_text text,
  settings_json jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.financial_accounts add column chart_account_id uuid;
alter table public.financial_accounts
  add constraint financial_accounts_chart_account_fk
  foreign key (business_id,chart_account_id)
  references public.chart_of_accounts(business_id,id) on delete restrict;

create table public.business_accounting_settings (
  business_id uuid primary key references public.businesses(id) on delete restrict,
  default_cash_account_id uuid,
  default_bank_account_id uuid,
  default_cash_financial_account_id uuid,
  default_bank_financial_account_id uuid,
  default_receivable_account_id uuid,
  default_payable_account_id uuid,
  default_inventory_account_id uuid,
  default_sales_account_id uuid,
  default_cogs_account_id uuid,
  default_expense_account_id uuid,
  settings_json jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  foreign key (business_id,default_cash_account_id) references public.chart_of_accounts(business_id,id) on delete restrict,
  foreign key (business_id,default_cash_financial_account_id) references public.financial_accounts(business_id,id) on delete restrict,
  foreign key (business_id,default_bank_financial_account_id) references public.financial_accounts(business_id,id) on delete restrict,
  foreign key (business_id,default_bank_account_id) references public.chart_of_accounts(business_id,id) on delete restrict,
  foreign key (business_id,default_inventory_account_id) references public.chart_of_accounts(business_id,id) on delete restrict,
  foreign key (business_id,default_cogs_account_id) references public.chart_of_accounts(business_id,id) on delete restrict,
  foreign key (business_id,default_receivable_account_id) references public.chart_of_accounts(business_id,id) on delete restrict,
  foreign key (business_id,default_payable_account_id) references public.chart_of_accounts(business_id,id) on delete restrict,
  foreign key (business_id,default_sales_account_id) references public.chart_of_accounts(business_id,id) on delete restrict,
  foreign key (business_id,default_expense_account_id) references public.chart_of_accounts(business_id,id) on delete restrict
);

create table public.business_inventory_settings (
  business_id uuid primary key references public.businesses(id) on delete restrict,
  default_warehouse_id uuid,
  allow_negative_stock boolean not null default false,
  costing_method text not null default 'weighted_average' check (costing_method in ('weighted_average','fifo')),
  settings_json jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  foreign key (business_id,default_warehouse_id) references public.warehouses(business_id,id) on delete restrict
);

create table public.sms_settings (
  business_id uuid primary key references public.businesses(id) on delete restrict,
  provider_code text not null default 'faraz',
  sender_number text,
  brand_name text,
  auto_invoice boolean not null default false,
  auto_payment boolean not null default false,
  test_phone text,
  settings_json jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
  -- Provider API credentials are stored in server-side secrets, never here.
);

create table public.sms_templates (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  template_type text not null,
  provider_pattern text,
  body text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (business_id,id),
  unique (business_id,template_type)
);

create table public.sms_history (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  contact_id uuid,
  template_id uuid,
  phone text not null,
  message_type text not null,
  provider_message_id text,
  status text not null check (status in ('queued','sent','delivered','failed','unknown')),
  sent_at timestamptz,
  response_summary text,
  source_type text,
  source_id uuid,
  created_at timestamptz not null default now(),
  foreign key (business_id,contact_id) references public.contacts(business_id,id) on delete restrict,
  foreign key (business_id,template_id) references public.sms_templates(business_id,id) on delete restrict
);
create index sms_history_date_idx on public.sms_history(business_id,created_at desc);

create table public.due_date_reminders (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  contact_id uuid,
  title text not null,
  due_date date not null,
  amount bigint,
  reminder_kind text not null,
  notes text,
  status text not null default 'pending' check (status in ('pending','done','dismissed')),
  created_at timestamptz not null default now(),
  foreign key (business_id,contact_id) references public.contacts(business_id,id) on delete restrict
);

create table public.file_attachments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  storage_bucket text not null,
  storage_path text not null,
  file_name text,
  mime_type text,
  file_size bigint check (file_size is null or file_size >= 0),
  entity_type text,
  entity_id uuid,
  uploaded_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (storage_bucket,storage_path)
);

create table public.subscription_plans (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  title text not null,
  billing_period text not null check (billing_period in ('free','monthly','yearly','lifetime')),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.plan_features (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references public.subscription_plans(id) on delete cascade,
  feature_code text not null,
  limit_value bigint,
  enabled boolean not null default true,
  unique (plan_id,feature_code)
);

insert into public.subscription_plans(code,title,billing_period,is_active)
values ('free','Free','free',true)
on conflict(code) do nothing;

insert into public.plan_features(plan_id,feature_code,limit_value,enabled)
select p.id,f.feature_code,f.limit_value,f.enabled
from public.subscription_plans p
cross join (values
  ('invoices.daily_limit',2::bigint,true),
  ('contacts.customers.limit',5::bigint,true),
  ('catalog.products.limit',5::bigint,true),
  ('invoice.items.limit',2::bigint,true),
  ('sms.test_mode',1::bigint,true),
  ('sms.auto_send',0::bigint,false),
  ('reports.financial',0::bigint,false),
  ('reports.sales_trend_days',0::bigint,false),
  ('invoice.templates.limit',2::bigint,true),
  ('invoice.colors.limit',2::bigint,true),
  ('invoice.export.pdf',1::bigint,true),
  ('invoice.export.print',0::bigint,false),
  ('advanced_settings.enabled',0::bigint,false)
) as f(feature_code,limit_value,enabled)
where p.code='free'
on conflict(plan_id,feature_code) do nothing;

create table public.business_subscriptions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  plan_id uuid not null references public.subscription_plans(id) on delete restrict,
  status text not null check (status in ('trialing','active','past_due','expired','cancelled','lifetime')),
  starts_at timestamptz not null,
  ends_at timestamptz,
  provider_code text,
  provider_reference text,
  created_at timestamptz not null default now(),
  unique (business_id,id),
  check (ends_at is null or ends_at > starts_at)
);

create table public.business_entitlements (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  feature_code text not null,
  enabled boolean not null,
  limit_value bigint,
  source_type text not null,
  source_id uuid,
  valid_from timestamptz not null default now(),
  valid_until timestamptz,
  created_at timestamptz not null default now(),
  check (valid_until is null or valid_until > valid_from)
);
create index business_entitlements_active_idx on public.business_entitlements(business_id,feature_code,valid_from,valid_until);

create table public.business_license_links (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  license_table text not null check (license_table in ('app_licenses','factori_license_keys')),
  license_id uuid not null,
  status text not null default 'active' check (status in ('active','revoked','unlinked')),
  linked_by uuid references public.profiles(id),
  linked_at timestamptz not null default now(),
  unique (license_table,license_id),
  unique (business_id,id)
);

create table public.business_license_claim_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  license_link_id uuid,
  event_type text not null,
  actor_user_id uuid references public.profiles(id),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  foreign key (business_id,license_link_id) references public.business_license_links(business_id,id) on delete restrict
);

create table public.sync_devices (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  user_id uuid not null references public.profiles(id),
  device_name text,
  platform text not null check (platform in ('android','web','ios','other')),
  device_public_key jsonb,
  status text not null default 'active' check (status in ('active','revoked')),
  last_seen_at timestamptz,
  created_at timestamptz not null default now(),
  unique (business_id,id)
);

create table public.sync_operations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  device_id uuid not null,
  operation_id uuid not null,
  operation_type text not null,
  record_type text not null,
  record_id uuid,
  base_version bigint,
  result_version bigint,
  status text not null default 'received' check (status in ('received','applied','conflict','rejected')),
  result_payload jsonb,
  created_at timestamptz not null default now(),
  unique (business_id,device_id,operation_id),
  foreign key (business_id,device_id) references public.sync_devices(business_id,id) on delete restrict
);
create index sync_operations_device_idx on public.sync_operations(business_id,device_id,created_at);

create table public.sync_cursors (
  business_id uuid not null,
  device_id uuid not null,
  last_revision bigint not null default 0,
  last_synced_at timestamptz,
  primary key (business_id,device_id),
  foreign key (business_id,device_id) references public.sync_devices(business_id,id) on delete cascade
);

create table public.record_revisions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  record_type text not null,
  record_id uuid not null,
  revision bigint not null,
  changed_by uuid references public.profiles(id),
  change_type text not null,
  change_payload jsonb,
  changed_at timestamptz not null default now(),
  unique (business_id,record_type,record_id,revision)
);

create table public.migration_batches (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  source_app text not null default 'factoori_android',
  source_schema_version text,
  source_currency_unit text,
  status text not null default 'staged' check (status in ('staged','validating','ready','importing','completed','failed')),
  started_at timestamptz,
  completed_at timestamptz,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (business_id,id)
);

alter table public.inventory_opening_balances
  add constraint inventory_opening_balances_batch_fk
  foreign key (business_id,source_migration_batch_id)
  references public.migration_batches(business_id,id) on delete restrict;

create table public.legacy_records (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  migration_batch_id uuid not null,
  source_collection text not null,
  legacy_id text not null,
  raw_payload jsonb not null,
  source_currency text,
  legacy_currency_unit text,
  currency_migration_status text not null default 'unresolved' check (currency_migration_status in ('unresolved','verified_irr','verified_irt','converted','needs_review')),
  mapping_status text not null default 'pending' check (mapping_status in ('pending','mapped','needs_review','rejected','archived')),
  mapping_error text,
  target_table text,
  target_id uuid,
  created_at timestamptz not null default now(),
  foreign key (business_id,migration_batch_id) references public.migration_batches(business_id,id) on delete restrict,
  unique (business_id,migration_batch_id,source_collection,legacy_id)
);

create table public.legacy_id_map (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  migration_batch_id uuid not null,
  source_collection text not null,
  legacy_id text not null,
  target_table text not null,
  target_id uuid not null,
  created_at timestamptz not null default now(),
  foreign key (business_id,migration_batch_id) references public.migration_batches(business_id,id) on delete restrict,
  unique (business_id,source_collection,legacy_id),
  unique (business_id,target_table,target_id)
);

commit;
