-- 003: Financial accounts, transactions, cheque lifecycle, contact ledger and journal primitives.
-- DEVELOPMENT DRAFT ONLY. Depends on 001_identity_business_permissions.sql and 002_core_documents.sql.
-- This migration defines storage and read policies only. No posting/payment RPC is exposed yet.
begin;

insert into public.permission_catalog(code,description,is_sensitive) values
 ('accounting.journal.read','Read accounting journal and ledger',false),
 ('accounting.journal.post','Post balanced accounting journal entries',false),
 ('payments.refund','Issue validated customer refunds',false),
 ('payments.allocate','Allocate receipts and payments to open documents',false)
on conflict(code) do nothing;

insert into public.business_role_permissions(role_code,permission_code,allowed)
select roles.role_code,p.code,
 case
  when roles.role_code='owner' then true
  when roles.role_code='admin' then p.code<>'audit.read'
  when roles.role_code='accountant' then p.code in (
   'accounting.journal.read','accounting.journal.post','payments.refund','payments.allocate')
  else false
 end
from (values ('owner'),('admin'),('accountant'),('sales'),('viewer')) roles(role_code)
cross join public.permission_catalog p
where p.code in ('accounting.journal.read','accounting.journal.post','payments.refund','payments.allocate')
on conflict(role_code,permission_code) do nothing;

create table if not exists public.financial_accounts (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 name text not null check(length(btrim(name)) between 1 and 120),
 account_type text not null check(account_type in ('cash','bank','wallet','clearing')),
 currency_code text not null default 'IRR' check(currency_code ~ '^[A-Z]{3}$'),
 is_active boolean not null default true,
 is_default boolean not null default false,
 opening_balance numeric(20,0) not null default 0,
 opening_balance_date date,
 legacy_id text,
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 version bigint not null default 1 check(version>0),
 unique(business_id,id),
 unique(business_id,legacy_id)
);
create unique index if not exists financial_accounts_one_default
 on public.financial_accounts(business_id) where is_default and is_active;
create index if not exists financial_accounts_business_idx
 on public.financial_accounts(business_id,is_active,account_type);

create table if not exists public.financial_transactions (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 transaction_type text not null check(transaction_type in
  ('customer_receipt','supplier_payment','expense_payment','other_income','customer_refund',
   'creditor_payment','account_transfer_in','account_transfer_out','cheque_deposit','opening_balance','adjustment')),
 direction text not null check(direction in ('in','out')),
 amount numeric(20,0) not null check(amount>0),
 currency_code text not null default 'IRR' check(currency_code ~ '^[A-Z]{3}$'),
 transaction_date date not null,
 account_id uuid,
 contact_id uuid,
 document_id uuid,
 reference_number text,
 description text,
 status text not null default 'posted' check(status in ('draft','posted','voided')),
 idempotency_key text,
 source_legacy_id text,
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 version bigint not null default 1 check(version>0),
 unique(business_id,id),
 unique(business_id,idempotency_key),
 unique(business_id,source_legacy_id),
 foreign key(business_id,account_id) references public.financial_accounts(business_id,id),
 foreign key(business_id,contact_id) references public.contacts(business_id,id),
 foreign key(business_id,document_id) references public.documents(business_id,id)
);
create index if not exists financial_transactions_business_date_idx
 on public.financial_transactions(business_id,transaction_date desc,id);
create index if not exists financial_transactions_contact_idx
 on public.financial_transactions(business_id,contact_id,transaction_date desc);
create index if not exists financial_transactions_account_idx
 on public.financial_transactions(business_id,account_id,transaction_date desc);

create table if not exists public.transaction_allocations (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null,
 transaction_id uuid not null,
 document_id uuid not null,
 amount numeric(20,0) not null check(amount>0),
 created_at timestamptz not null default now(),
 created_by uuid references auth.users(id) on delete set null,
 unique(business_id,id),
 foreign key(business_id,transaction_id) references public.financial_transactions(business_id,id) on delete cascade,
 foreign key(business_id,document_id) references public.documents(business_id,id)
);
create index if not exists transaction_allocations_document_idx
 on public.transaction_allocations(business_id,document_id);
create index if not exists transaction_allocations_transaction_idx
 on public.transaction_allocations(business_id,transaction_id);

create table if not exists public.cheques (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 cheque_direction text not null check(cheque_direction in ('received','issued')),
 cheque_number text,
 sayad_id text,
 bank_name text,
 branch_name text,
 account_number text,
 account_holder text,
 drawer_name text,
 payee_name text,
 amount numeric(20,0) not null check(amount>0),
 currency_code text not null default 'IRR' check(currency_code ~ '^[A-Z]{3}$'),
 issue_date date,
 due_date date not null,
 status text not null default 'pending' check(status in
  ('pending','deposited','transferred','cleared','bounced','cancelled','returned')),
 contact_id uuid,
 related_transaction_id uuid,
 image_object_path text,
 note text,
 legacy_id text,
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 version bigint not null default 1 check(version>0),
 unique(business_id,id),
 unique(business_id,legacy_id),
 foreign key(business_id,contact_id) references public.contacts(business_id,id),
 foreign key(business_id,related_transaction_id) references public.financial_transactions(business_id,id),
 check(issue_date is null or due_date>=issue_date)
);
create index if not exists cheques_business_due_idx on public.cheques(business_id,due_date,status);
create index if not exists cheques_contact_idx on public.cheques(business_id,contact_id,due_date);

create table if not exists public.cheque_events (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null,
 cheque_id uuid not null,
 event_type text not null check(event_type in
  ('created','deposited','transferred','cleared','bounced','cancelled','returned','corrected')),
 event_date timestamptz not null default now(),
 from_status text,
 to_status text,
 amount numeric(20,0) check(amount is null or amount>0),
 related_transaction_id uuid,
 related_contact_id uuid,
 note text,
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 foreign key(business_id,cheque_id) references public.cheques(business_id,id) on delete cascade,
 foreign key(business_id,related_transaction_id) references public.financial_transactions(business_id,id),
 foreign key(business_id,related_contact_id) references public.contacts(business_id,id)
);
create index if not exists cheque_events_timeline_idx
 on public.cheque_events(business_id,cheque_id,event_date,id);

create table if not exists public.chart_of_accounts (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 code text not null,
 name text not null check(length(btrim(name)) between 1 and 160),
 account_class text not null check(account_class in ('asset','liability','equity','income','expense')),
 parent_account_id uuid,
 is_system boolean not null default false,
 is_active boolean not null default true,
 allow_posting boolean not null default true,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(business_id,id),
 unique(business_id,code),
 foreign key(business_id,parent_account_id) references public.chart_of_accounts(business_id,id)
);
create index if not exists chart_accounts_parent_idx on public.chart_of_accounts(business_id,parent_account_id);

create table if not exists public.journal_entries (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 entry_number text,
 entry_date date not null,
 fiscal_period_id uuid,
 source_type text not null check(source_type in
  ('document','financial_transaction','cheque_event','opening_balance','manual','reversal')),
 source_id uuid,
 description text,
 status text not null default 'draft' check(status in ('draft','posted','reversed')),
 reverses_entry_id uuid,
 idempotency_key text,
 posted_at timestamptz,
 posted_by uuid references auth.users(id) on delete set null,
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 version bigint not null default 1 check(version>0),
 unique(business_id,id),
 unique(business_id,entry_number),
 unique(business_id,idempotency_key),
 foreign key(business_id,fiscal_period_id) references public.fiscal_periods(business_id,id),
 foreign key(business_id,reverses_entry_id) references public.journal_entries(business_id,id)
);
create index if not exists journal_entries_date_idx on public.journal_entries(business_id,entry_date desc,status);

create table if not exists public.journal_lines (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null,
 journal_entry_id uuid not null,
 account_id uuid not null,
 contact_id uuid,
 debit numeric(20,0) not null default 0 check(debit>=0),
 credit numeric(20,0) not null default 0 check(credit>=0),
 description text,
 line_order integer not null default 0,
 created_at timestamptz not null default now(),
 foreign key(business_id,journal_entry_id) references public.journal_entries(business_id,id) on delete cascade,
 foreign key(business_id,account_id) references public.chart_of_accounts(business_id,id),
 foreign key(business_id,contact_id) references public.contacts(business_id,id),
 check((debit>0 and credit=0) or (credit>0 and debit=0))
);
create index if not exists journal_lines_entry_idx on public.journal_lines(business_id,journal_entry_id,line_order);
create index if not exists journal_lines_account_idx on public.journal_lines(business_id,account_id);

create table if not exists public.contact_ledger_entries (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null,
 contact_id uuid not null,
 entry_date date not null,
 entry_type text not null check(entry_type in
  ('opening_debit','opening_credit','invoice_debit','invoice_credit','receipt','payment',
   'sales_return','purchase_return','adjustment_debit','adjustment_credit','writeoff')),
 debit numeric(20,0) not null default 0 check(debit>=0),
 credit numeric(20,0) not null default 0 check(credit>=0),
 document_id uuid,
 transaction_id uuid,
 description text,
 source_legacy_id text,
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 foreign key(business_id,contact_id) references public.contacts(business_id,id),
 foreign key(business_id,document_id) references public.documents(business_id,id),
 foreign key(business_id,transaction_id) references public.financial_transactions(business_id,id),
 unique(business_id,source_legacy_id),
 check((debit>0 and credit=0) or (credit>0 and debit=0))
);
create index if not exists contact_ledger_contact_date_idx
 on public.contact_ledger_entries(business_id,contact_id,entry_date desc,id);

-- updated_at helpers from migration 001.
drop trigger if exists financial_accounts_touch_updated_at on public.financial_accounts;
create trigger financial_accounts_touch_updated_at before update on public.financial_accounts
for each row execute function private.touch_updated_at();
drop trigger if exists financial_transactions_touch_updated_at on public.financial_transactions;
create trigger financial_transactions_touch_updated_at before update on public.financial_transactions
for each row execute function private.touch_updated_at();
drop trigger if exists cheques_touch_updated_at on public.cheques;
create trigger cheques_touch_updated_at before update on public.cheques
for each row execute function private.touch_updated_at();
drop trigger if exists chart_accounts_touch_updated_at on public.chart_of_accounts;
create trigger chart_accounts_touch_updated_at before update on public.chart_of_accounts
for each row execute function private.touch_updated_at();
drop trigger if exists journal_entries_touch_updated_at on public.journal_entries;
create trigger journal_entries_touch_updated_at before update on public.journal_entries
for each row execute function private.touch_updated_at();

alter table public.financial_accounts enable row level security;
alter table public.financial_transactions enable row level security;
alter table public.transaction_allocations enable row level security;
alter table public.cheques enable row level security;
alter table public.cheque_events enable row level security;
alter table public.chart_of_accounts enable row level security;
alter table public.journal_entries enable row level security;
alter table public.journal_lines enable row level security;
alter table public.contact_ledger_entries enable row level security;

drop policy if exists financial_accounts_read on public.financial_accounts;
create policy financial_accounts_read on public.financial_accounts for select to authenticated
 using(private.has_business_permission(business_id,'payments.read'));
drop policy if exists financial_transactions_read on public.financial_transactions;
create policy financial_transactions_read on public.financial_transactions for select to authenticated
 using(private.has_business_permission(business_id,'payments.read'));
drop policy if exists transaction_allocations_read on public.transaction_allocations;
create policy transaction_allocations_read on public.transaction_allocations for select to authenticated
 using(private.has_business_permission(business_id,'payments.read'));
drop policy if exists cheques_read on public.cheques;
create policy cheques_read on public.cheques for select to authenticated
 using(private.has_business_permission(business_id,'cheques.read'));
drop policy if exists cheque_events_read on public.cheque_events;
create policy cheque_events_read on public.cheque_events for select to authenticated
 using(private.has_business_permission(business_id,'cheques.read'));
drop policy if exists chart_of_accounts_read on public.chart_of_accounts;
create policy chart_of_accounts_read on public.chart_of_accounts for select to authenticated
 using(private.has_business_permission(business_id,'accounting.journal.read'));
drop policy if exists journal_entries_read on public.journal_entries;
create policy journal_entries_read on public.journal_entries for select to authenticated
 using(private.has_business_permission(business_id,'accounting.journal.read'));
drop policy if exists journal_lines_read on public.journal_lines;
create policy journal_lines_read on public.journal_lines for select to authenticated
 using(private.has_business_permission(business_id,'accounting.journal.read'));
drop policy if exists contact_ledger_read on public.contact_ledger_entries;
create policy contact_ledger_read on public.contact_ledger_entries for select to authenticated
 using(private.has_business_permission(business_id,'contacts.ledger.read'));

revoke all on public.financial_accounts,public.financial_transactions,public.transaction_allocations,
 public.cheques,public.cheque_events,public.chart_of_accounts,public.journal_entries,
 public.journal_lines,public.contact_ledger_entries from public,anon;
grant select on public.financial_accounts,public.financial_transactions,public.transaction_allocations,
 public.cheques,public.cheque_events,public.chart_of_accounts,public.journal_entries,
 public.journal_lines,public.contact_ledger_entries to authenticated;

commit;
