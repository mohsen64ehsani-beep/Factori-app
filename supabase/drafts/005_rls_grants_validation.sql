-- DRAFT ONLY. Depends on 001-004. Do not apply to production.
begin;

-- RLS is enabled on every public table. Direct client writes are intentionally not granted;
-- financial, inventory and document mutations must be performed by audited transactional RPCs.
do $$
declare r record;
begin
  for r in
    select n.nspname, c.relname
    from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind='r'
      and c.relname not in ('profiles','permission_catalog')
  loop
    execute format('alter table %I.%I enable row level security',r.nspname,r.relname);
  end loop;
end $$;

alter table public.profiles enable row level security;
alter table public.permission_catalog enable row level security;
alter table private.document_item_costs enable row level security;
alter table private.product_costs enable row level security;
alter table private.stock_movement_costs enable row level security;
alter table private.warehouse_stock_cost_balances enable row level security;
alter table private.inventory_opening_costs enable row level security;
alter table private.inventory_cost_layers enable row level security;
alter table private.inventory_cost_allocations enable row level security;
alter table private.business_invitations enable row level security;
create policy profiles_select_self on public.profiles
for select to authenticated
using (id=(select auth.uid()));

create policy profiles_update_self on public.profiles
for update to authenticated
using (id=(select auth.uid()))
with check (id=(select auth.uid()));

create policy permission_catalog_read on public.permission_catalog
for select to authenticated using (true);

create policy businesses_read_member on public.businesses
for select to authenticated
using ((select private.is_business_member(id)));

create policy business_members_read_self_or_authorized on public.business_members
for select to authenticated
using (
  user_id=(select auth.uid())
  or (select private.has_business_permission(business_id,'members.read'))
);

-- Per-table read permission map. All writes remain RPC-only.
do $$
declare
  x record;
begin
  for x in
    select * from (values
      ('business_role_permissions','members.read'),
      ('business_member_permission_overrides','members.read'),
      ('business_audit_logs','audit.read'),
      ('contacts','contacts.read'),
      ('contact_addresses','contacts.read'),
      ('product_categories','catalog.read'),
      ('products','catalog.read'),
      ('services','catalog.read'),
      ('warehouses','inventory.read'),
      ('fiscal_periods','sales.read'),
      ('invoice_number_sequences','sales.read'),
      ('documents','sales.read'),
      ('document_items','sales.read'),
      ('document_events','sales.read'),
      ('financial_accounts','payments.read'),
      ('financial_transactions','payments.read'),
      ('transaction_allocations','payments.read'),
      ('transaction_allocation_reversals','payments.read'),
      ('business_bank_details','invoice.settings.read'),
      ('cheques','cheques.read'),
      ('cheque_events','cheques.read'),
      ('cheque_assignments','cheques.read'),
      ('stock_movements','inventory.read'),
      ('warehouse_stock_balances','inventory.read'),
      ('stock_transfers','inventory.read'),
      ('stock_transfer_items','inventory.read'),
      ('inventory_opening_balances','inventory.read'),
      ('opening_balances','payments.read'),
      ('chart_of_accounts','accounting.ledger.read'),
      ('journal_entries','accounting.ledger.read'),
      ('journal_lines','accounting.ledger.read'),
      ('business_settings','settings.read'),
      ('business_invoice_settings','invoice.settings.read'),
      ('business_accounting_settings','settings.manage'),
      ('business_inventory_settings','settings.manage'),
      ('sms_settings','settings.manage'),
      ('sms_templates','settings.manage'),
      ('sms_history','settings.manage'),
      ('due_date_reminders','contacts.read'),
      ('file_attachments','sales.read'),
      ('subscription_plans','settings.manage'),
      ('plan_features','settings.manage'),
      ('business_subscriptions','settings.manage'),
      ('business_entitlements','settings.manage'),
      ('business_license_links','settings.manage'),
      ('business_license_claim_events','settings.manage'),
      ('sync_devices','members.read'),
      ('sync_operations','members.read'),
      ('sync_cursors','members.read'),
      ('record_revisions','audit.read'),
      ('migration_batches','settings.manage'),
      ('legacy_records','settings.manage'),
      ('legacy_id_map','settings.manage')
    ) as p(table_name,permission_code)
  loop
    execute format(
      'create policy %I on public.%I for select to authenticated using ((select private.has_business_permission(business_id,%L)))',
      x.table_name || '_read_policy', x.table_name, x.permission_code
    );
  end loop;
end $$;

-- No direct access to sensitive costs, even for authenticated users. Dedicated RPCs may expose
-- only the fields permitted by catalog.cost.read / reports.profit.read.
revoke all on table private.document_item_costs from public, anon, authenticated;
revoke all on table private.product_costs from public, anon, authenticated;

-- Public Data API read grants are explicit. Data API schema exposure must also be enabled
-- deliberately in project settings; this grant alone does not expose a schema.
grant select on all tables in schema public to authenticated;
revoke insert, update, delete, truncate, references, trigger on all tables in schema public from anon, authenticated;
grant select on public.profiles, public.permission_catalog to authenticated;

-- Bootstrap a business and its owner membership atomically.
create or replace function private.create_business(p_name text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_business_id uuid;
  v_warehouse_id uuid;
  v_cash_financial_account_id uuid;
  v_bank_financial_account_id uuid;
  v_subscription_id uuid;
begin
  if v_user is null then
    raise exception 'authentication_required' using errcode='28000';
  end if;
  if p_name is null or length(trim(p_name))=0 then
    raise exception 'business_name_required' using errcode='22023';
  end if;
  insert into public.profiles(id) values(v_user) on conflict(id) do nothing;
  insert into public.businesses(name,owner_user_id)
  values(trim(p_name),v_user)
  returning id into v_business_id;
  insert into public.business_members(business_id,user_id,role_code,status,joined_at)
  values(v_business_id,v_user,'owner','active',now());

  insert into public.business_role_permissions(business_id,role_code,permission_code,is_allowed)
  select v_business_id, defaults.role_code, defaults.permission_code, true
  from (values
    ('admin','contacts.read'),('admin','contacts.write'),('admin','catalog.read'),('admin','catalog.write'),
    ('admin','catalog.cost.read'),('admin','sales.read'),('admin','sales.create'),('admin','sales.edit_draft'),
    ('admin','sales.post'),('admin','purchases.read'),('admin','purchases.create'),('admin','payments.read'),
    ('admin','payments.create'),('admin','cheques.read'),('admin','cheques.update_status'),('admin','inventory.read'),
    ('admin','inventory.adjust'),('admin','inventory.transfer'),('admin','expenses.read'),('admin','expenses.create'),
    ('admin','reports.basic.read'),('admin','reports.profit.read'),('admin','settings.manage'),('admin','members.read'),
    ('admin','members.manage'),('admin','audit.read'),('admin','accounting.ledger.read'),('admin','accounting.journal.post'),('admin','settings.read'),('admin','invoice.settings.read'),
    ('accountant','contacts.read'),('accountant','contacts.write'),('accountant','catalog.read'),('accountant','catalog.cost.read'),
    ('accountant','sales.read'),('accountant','sales.create'),('accountant','sales.edit_draft'),('accountant','sales.post'),
    ('accountant','purchases.read'),('accountant','purchases.create'),('accountant','payments.read'),('accountant','payments.create'),
    ('accountant','cheques.read'),('accountant','cheques.update_status'),('accountant','inventory.read'),
    ('accountant','expenses.read'),('accountant','expenses.create'),('accountant','reports.basic.read'),
    ('accountant','reports.profit.read'),('accountant','audit.read'),('accountant','accounting.ledger.read'),('accountant','accounting.journal.post'),('accountant','settings.read'),('accountant','invoice.settings.read'),
    ('sales','contacts.read'),('sales','contacts.write'),('sales','catalog.read'),('sales','sales.read'),
    ('sales','sales.create'),('sales','sales.edit_draft'),('sales','sales.post'),('sales','inventory.read'),
    ('sales','settings.read'),('sales','invoice.settings.read'),
    ('viewer','contacts.read'),('viewer','catalog.read'),('viewer','sales.read'),('viewer','inventory.read'),('viewer','reports.basic.read'),('viewer','settings.read'),('viewer','invoice.settings.read')
  ) as defaults(role_code,permission_code)
  join public.permission_catalog pc on pc.code=defaults.permission_code;


  insert into public.business_settings(business_id) values(v_business_id);
  insert into public.business_invoice_settings(business_id) values(v_business_id);
  insert into public.sms_settings(business_id) values(v_business_id);

  insert into public.warehouses(business_id,name,code,is_default)
  values(v_business_id,'انبار اصلی','MAIN',true)
  returning id into v_warehouse_id;

  insert into public.financial_accounts(business_id,name,account_type,currency_code)
  values(v_business_id,'صندوق اصلی','cash','IRR')
  returning id into v_cash_financial_account_id;
  insert into public.financial_accounts(business_id,name,account_type,currency_code)
  values(v_business_id,'بانک اصلی','bank','IRR')
  returning id into v_bank_financial_account_id;

  insert into public.chart_of_accounts(business_id,code,name,account_group,normal_balance)
  values
    (v_business_id,'1000','صندوق','asset','debit'),
    (v_business_id,'1010','بانک','asset','debit'),
    (v_business_id,'1100','حساب‌های دریافتنی','asset','debit'),
    (v_business_id,'1200','موجودی کالا','asset','debit'),
    (v_business_id,'2000','حساب‌های پرداختنی','liability','credit'),
    (v_business_id,'2100','مالیات پرداختنی','liability','credit'),
    (v_business_id,'3000','سرمایه','equity','credit'),
    (v_business_id,'4000','فروش کالا','revenue','credit'),
    (v_business_id,'4100','درآمد خدمات','revenue','credit'),
    (v_business_id,'5000','بهای تمام‌شده','expense','debit'),
    (v_business_id,'6000','هزینه‌های جاری','expense','debit'),
    (v_business_id,'6100','ضایعات','expense','debit'),
    (v_business_id,'7000','سایر درآمدها','revenue','credit');

  update public.financial_accounts fa
  set chart_account_id=ca.id
  from public.chart_of_accounts ca
  where fa.business_id=v_business_id and ca.business_id=v_business_id
    and ((fa.account_type='cash' and ca.code='1000') or (fa.account_type='bank' and ca.code='1010'));

  insert into public.business_accounting_settings(
    business_id,default_cash_account_id,default_bank_account_id,
    default_cash_financial_account_id,default_bank_financial_account_id,
    default_receivable_account_id,default_payable_account_id,
    default_inventory_account_id,default_sales_account_id,
    default_cogs_account_id,default_expense_account_id
  ) values (
    v_business_id,
    (select id from public.chart_of_accounts where business_id=v_business_id and code='1000'),
    (select id from public.chart_of_accounts where business_id=v_business_id and code='1010'),
    v_cash_financial_account_id,v_bank_financial_account_id,
    (select id from public.chart_of_accounts where business_id=v_business_id and code='1100'),
    (select id from public.chart_of_accounts where business_id=v_business_id and code='2000'),
    (select id from public.chart_of_accounts where business_id=v_business_id and code='1200'),
    (select id from public.chart_of_accounts where business_id=v_business_id and code='4000'),
    (select id from public.chart_of_accounts where business_id=v_business_id and code='5000'),
    (select id from public.chart_of_accounts where business_id=v_business_id and code='6000')
  );

  insert into public.business_inventory_settings(business_id,default_warehouse_id)
  values(v_business_id,v_warehouse_id);

  insert into public.invoice_number_sequences(business_id,document_type,prefix,next_number,number_padding,reset_policy)
  values
    (v_business_id,'sale','',1,0,'never'),
    (v_business_id,'service_sale','',1,0,'never'),
    (v_business_id,'purchase','',1,0,'never'),
    (v_business_id,'sales_return','',1,0,'never'),
    (v_business_id,'purchase_return','',1,0,'never');

  insert into public.business_subscriptions(business_id,plan_id,status,starts_at)
  select v_business_id,id,'active',now()
  from public.subscription_plans where code='free'
  returning id into v_subscription_id;

  insert into public.business_entitlements(business_id,feature_code,enabled,limit_value,source_type,source_id)
  select v_business_id,pf.feature_code,pf.enabled,pf.limit_value,'subscription',v_subscription_id
  from public.plan_features pf
  join public.business_subscriptions bs on bs.plan_id=pf.plan_id
  where bs.id=v_subscription_id;

  return v_business_id;
end;
$$;
revoke all on function private.create_business(text) from public,anon;
grant execute on function private.create_business(text) to authenticated;

-- Atomic server-side invoice number allocation. Caller must still create the document in
-- the same transaction/RPC that consumes this number.
create or replace function private.next_document_number(
  p_business_id uuid,
  p_document_type text,
  p_fiscal_period_id uuid default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prefix text;
  v_next bigint;
  v_padding smallint;
begin
  if p_document_type not in ('sale','service_sale','purchase','sales_return','purchase_return') then
    raise exception 'unsupported_document_type' using errcode='22023';
  end if;
  if auth.uid() is null or not (select private.is_business_member(p_business_id)) then
    raise exception 'not_authorized' using errcode='42501';
  end if;
  if p_document_type in ('sale','service_sale','sales_return')
     and not (select private.has_business_permission(p_business_id,'sales.create')) then
    raise exception 'not_authorized' using errcode='42501';
  end if;
  if p_document_type in ('purchase','purchase_return')
     and not (select private.has_business_permission(p_business_id,'purchases.create')) then
    raise exception 'not_authorized' using errcode='42501';
  end if;

  select prefix,next_number,number_padding
    into v_prefix,v_next,v_padding
  from public.invoice_number_sequences
  where business_id=p_business_id
    and document_type=p_document_type
    and fiscal_period_id is not distinct from p_fiscal_period_id
  for update;

  if not found then
    raise exception 'invoice_sequence_not_configured' using errcode='P0002';
  end if;

  update public.invoice_number_sequences
  set next_number=next_number+1
  where business_id=p_business_id
    and document_type=p_document_type
    and fiscal_period_id is not distinct from p_fiscal_period_id;

  return coalesce(v_prefix,'') || lpad(v_next::text,v_padding,'0');
end;
$$;
revoke all on function private.next_document_number(uuid,text,uuid) from public,anon;
grant execute on function private.next_document_number(uuid,text,uuid) to authenticated;

-- Atomic allocation with row locks. This protects the invariant sum(allocations) <= transaction amount.
create or replace function private.allocate_payment(
  p_business_id uuid,
  p_transaction_id uuid,
  p_document_id uuid,
  p_amount bigint
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tx public.financial_transactions%rowtype;
  v_doc public.documents%rowtype;
  v_allocated bigint;
  v_id uuid;
begin
  if auth.uid() is null
     or not (select private.has_business_permission(p_business_id,'payments.create')) then
    raise exception 'not_authorized' using errcode='42501';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'invalid_allocation_amount' using errcode='22023';
  end if;

  select * into v_tx
  from public.financial_transactions
  where business_id=p_business_id and id=p_transaction_id
  for update;
  if not found or v_tx.status <> 'posted' then
    raise exception 'transaction_not_available' using errcode='P0002';
  end if;

  select * into v_doc
  from public.documents
  where business_id=p_business_id and id=p_document_id
  for update;
  if not found or v_doc.status <> 'posted' then
    raise exception 'document_not_available' using errcode='P0002';
  end if;

  if v_tx.contact_id is not null and v_doc.contact_id is not null
     and v_tx.contact_id <> v_doc.contact_id then
    raise exception 'contact_mismatch' using errcode='22023';
  end if;

  select coalesce(sum(a.allocated_amount),0)-coalesce((
    select sum(r.reversed_amount)
    from public.transaction_allocation_reversals r
    join public.transaction_allocations ar on ar.business_id=r.business_id and ar.id=r.allocation_id
    where ar.business_id=p_business_id and ar.transaction_id=p_transaction_id
  ),0) into v_allocated
  from public.transaction_allocations a
  where a.business_id=p_business_id and a.transaction_id=p_transaction_id;

  if v_allocated + p_amount > v_tx.amount then
    raise exception 'allocation_exceeds_transaction' using errcode='23514';
  end if;

  insert into public.transaction_allocations(business_id,transaction_id,document_id,allocated_amount,created_by)
  values(p_business_id,p_transaction_id,p_document_id,p_amount,auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function private.allocate_payment(uuid,uuid,uuid,bigint) from public,anon;
grant execute on function private.allocate_payment(uuid,uuid,uuid,bigint) to authenticated;

-- Post a balanced journal entry. Lines are locked and validated in the same transaction.
create or replace function private.post_journal_entry(p_business_id uuid,p_entry_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry public.journal_entries%rowtype;
  v_debit numeric;
  v_credit numeric;
  v_count integer;
  v_period_status text;
begin
  if auth.uid() is null
     or not (select private.has_business_permission(p_business_id,'accounting.journal.post')) then
    raise exception 'not_authorized' using errcode='42501';
  end if;

  select * into v_entry
  from public.journal_entries
  where business_id=p_business_id and id=p_entry_id
  for update;
  if not found or v_entry.status <> 'draft' then
    raise exception 'journal_entry_not_draft' using errcode='P0002';
  end if;

  if v_entry.fiscal_period_id is not null then
    select status into v_period_status
    from public.fiscal_periods
    where business_id=p_business_id and id=v_entry.fiscal_period_id
    for update;
    if v_period_status not in ('open','reopened') then
      raise exception 'fiscal_period_closed' using errcode='23514';
    end if;
  end if;

  select coalesce(sum(debit),0),coalesce(sum(credit),0),count(*)
    into v_debit,v_credit,v_count
  from public.journal_lines
  where business_id=p_business_id and journal_entry_id=p_entry_id;

  if v_count < 2 or v_debit <= 0 or v_debit <> v_credit then
    raise exception 'journal_entry_unbalanced' using errcode='23514';
  end if;

  update public.journal_entries
  set status='posted',posted_at=now(),posted_by=auth.uid()
  where business_id=p_business_id and id=p_entry_id;
end;
$$;
revoke all on function private.post_journal_entry(uuid,uuid) from public,anon;
grant execute on function private.post_journal_entry(uuid,uuid) to authenticated;



-- Immutable ledger and posted-document guards.
create or replace function private.reject_immutable_mutation()
returns trigger
language plpgsql
set search_path = ''
as $
begin
  raise exception 'immutable_record: create a reversal or corrective record'
    using errcode='55000';
end;
$;

create or replace function private.guard_posted_document()
returns trigger
language plpgsql
set search_path = ''
as $
begin
  if old.status='posted' then
    raise exception 'posted_document_immutable' using errcode='55000';
  end if;
  if tg_op='DELETE' then return old; else return new; end if;
end;
$;

create or replace function private.guard_document_item_parent()
returns trigger
language plpgsql
set search_path = ''
as $
declare v_business_id uuid; v_document_id uuid; v_status text;
begin
  if tg_op='DELETE' then
    v_business_id:=old.business_id; v_document_id:=old.document_id;
  else
    v_business_id:=new.business_id; v_document_id:=new.document_id;
  end if;
  select status into v_status from public.documents
  where business_id=v_business_id and id=v_document_id;
  if v_status='posted' then
    raise exception 'posted_document_items_immutable' using errcode='55000';
  end if;
  return case when tg_op='DELETE' then old else new end;
end;
$;

create or replace function private.guard_posted_journal_entry()
returns trigger
language plpgsql
set search_path = ''
as $
begin
  if old.status in ('posted','reversed') then
    raise exception 'posted_journal_entry_immutable' using errcode='55000';
  end if;
  return case when tg_op='DELETE' then old else new end;
end;
$;

create or replace function private.guard_journal_line_parent()
returns trigger
language plpgsql
set search_path = ''
as $
declare v_business_id uuid; v_entry_id uuid; v_status text;
begin
  if tg_op='DELETE' then
    v_business_id:=old.business_id; v_entry_id:=old.journal_entry_id;
  else
    v_business_id:=new.business_id; v_entry_id:=new.journal_entry_id;
  end if;
  select status into v_status from public.journal_entries
  where business_id=v_business_id and id=v_entry_id;
  if v_status in ('posted','reversed') then
    raise exception 'posted_journal_lines_immutable' using errcode='55000';
  end if;
  return case when tg_op='DELETE' then old else new end;
end;
$;

create trigger documents_posted_immutable
before update or delete on public.documents
for each row execute function private.guard_posted_document();

create trigger document_items_posted_immutable
before insert or update or delete on public.document_items
for each row execute function private.guard_document_item_parent();

create trigger journal_entries_posted_immutable
before update or delete on public.journal_entries
for each row execute function private.guard_posted_journal_entry();

create trigger journal_lines_posted_immutable
before insert or update or delete on public.journal_lines
for each row execute function private.guard_journal_line_parent();

create trigger stock_movements_append_only
before update or delete on public.stock_movements
for each row execute function private.reject_immutable_mutation();

create trigger cheque_events_append_only
before update or delete on public.cheque_events
for each row execute function private.reject_immutable_mutation();

create trigger document_events_append_only
before update or delete on public.document_events
for each row execute function private.reject_immutable_mutation();

create trigger business_audit_logs_append_only
before update or delete on public.business_audit_logs
for each row execute function private.reject_immutable_mutation();

create trigger record_revisions_append_only
before update or delete on public.record_revisions
for each row execute function private.reject_immutable_mutation();

create trigger transaction_allocations_append_only
before update or delete on public.transaction_allocations
for each row execute function private.reject_immutable_mutation();

create trigger transaction_allocation_reversals_append_only
before update or delete on public.transaction_allocation_reversals
for each row execute function private.reject_immutable_mutation();

create trigger opening_balances_append_only
before update or delete on public.opening_balances
for each row execute function private.reject_immutable_mutation();

create or replace function private.guard_posted_financial_transaction()
returns trigger
language plpgsql
set search_path = ''
as $
begin
  if old.status in ('posted','reversed') then
    raise exception 'posted_financial_transaction_immutable' using errcode='55000';
  end if;
  if tg_op='DELETE' then return old; else return new; end if;
end;
$;

create trigger financial_transactions_posted_immutable
before update or delete on public.financial_transactions
for each row execute function private.guard_posted_financial_transaction();

-- The function above is deliberately defined explicitly so draft transactions can be corrected,
-- while posted transactions are only reversed through a new transaction.
create or replace function private.guard_posted_financial_transaction()
returns trigger
language plpgsql
set search_path = ''
as $
begin
  if old.status in ('posted','reversed') then
    raise exception 'posted_financial_transaction_immutable' using errcode='55000';
  end if;
  return case when tg_op='DELETE' then old else new end;
end;
$;



-- Public invoker wrappers are the only client-facing entry points for these private routines.
create or replace function public.create_business(p_name text)
returns uuid
language sql
security invoker
set search_path = ''
as $ select private.create_business(p_name); $;

create or replace function public.allocate_payment(
  p_business_id uuid,p_transaction_id uuid,p_document_id uuid,p_amount bigint
)
returns uuid
language sql
security invoker
set search_path = ''
as $ select private.allocate_payment(p_business_id,p_transaction_id,p_document_id,p_amount); $;

create or replace function public.post_journal_entry(p_business_id uuid,p_entry_id uuid)
returns void
language sql
security invoker
set search_path = ''
as $ select private.post_journal_entry(p_business_id,p_entry_id); $;

revoke all on function public.create_business(text) from public,anon;
revoke all on function public.allocate_payment(uuid,uuid,uuid,bigint) from public,anon;
revoke all on function public.post_journal_entry(uuid,uuid) from public,anon;
grant execute on function public.create_business(text) to authenticated;
grant execute on function public.allocate_payment(uuid,uuid,uuid,bigint) to authenticated;
grant execute on function public.post_journal_entry(uuid,uuid) to authenticated;

-- Profiles are self-editable only for non-authoritative presentation fields.
grant update(display_name,phone,avatar_path) on public.profiles to authenticated;


commit;
