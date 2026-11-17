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
      and c.relname not in ('profiles','permission_catalog','user_device_settings','subscription_plans','plan_features')
  loop
    execute format('alter table %I.%I enable row level security',r.nspname,r.relname);
  end loop;
end $$;

alter table public.profiles enable row level security;
alter table public.permission_catalog enable row level security;
alter table public.subscription_plans enable row level security;
alter table public.plan_features enable row level security;
alter table private.document_item_costs enable row level security;
alter table private.document_cost_summaries enable row level security;
alter table private.product_costs enable row level security;
alter table private.stock_movement_costs enable row level security;
alter table private.warehouse_stock_cost_balances enable row level security;
alter table private.inventory_opening_costs enable row level security;
alter table private.inventory_cost_layers enable row level security;
alter table private.inventory_cost_allocations enable row level security;
alter table private.business_invitations enable row level security;
alter table private.feature_usage_counters enable row level security;
alter table private.feature_usage_events enable row level security;
create policy profiles_select_self on public.profiles
for select to authenticated
using (id=(select auth.uid()));

create policy profiles_update_self on public.profiles
for update to authenticated
using (id=(select auth.uid()))
with check (id=(select auth.uid()));

create policy permission_catalog_read on public.permission_catalog
for select to authenticated using (true);

create policy subscription_plans_read on public.subscription_plans
for select to authenticated using (true);

create policy plan_features_read on public.plan_features
for select to authenticated using (true);

create policy businesses_read_member on public.businesses
for select to authenticated
using ((select private.is_business_member(id)));

alter table public.user_device_settings enable row level security;
create policy user_device_settings_select_own on public.user_device_settings
for select to authenticated
using (user_id=(select auth.uid()) and (select private.is_business_member(business_id)));
create policy user_device_settings_insert_own on public.user_device_settings
for insert to authenticated
with check (user_id=(select auth.uid()) and (select private.is_business_member(business_id)));
create policy user_device_settings_update_own on public.user_device_settings
for update to authenticated
using (user_id=(select auth.uid()) and (select private.is_business_member(business_id)))
with check (user_id=(select auth.uid()) and (select private.is_business_member(business_id)));

grant insert,update on public.user_device_settings to authenticated;

create policy business_members_read_self_or_authorized on public.business_members
for select to authenticated
using (
  user_id=(select auth.uid())
  or (select private.has_business_permission(business_id,'members.read'))
);

-- Document access is type-aware so a sales role cannot read purchase/expense documents.

create or replace function private.can_read_document(p_business_id uuid,p_document_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_type text;
begin
  if auth.uid() is null or not (select private.is_business_member(p_business_id)) then
    return false;
  end if;
  select document_type into v_type
  from public.documents
  where business_id=p_business_id and id=p_document_id;
  if not found then return false; end if;
  if v_type in ('sale','service_sale','sales_return') then
    return (select private.has_business_permission(p_business_id,'sales.read'));
  elsif v_type in ('purchase','purchase_return') then
    return (select private.has_business_permission(p_business_id,'purchases.read'));
  elsif v_type in ('expense','other_income','wastage') then
    return (select private.has_business_permission(p_business_id,'expenses.read'));
  elsif v_type in ('opening_balance','adjustment') then
    return (select private.has_business_permission(p_business_id,'reports.basic.read'));
  end if;
  return false;
end;
$$;
revoke all on function private.can_read_document(uuid,uuid) from public,anon;
grant execute on function private.can_read_document(uuid,uuid) to authenticated;

create policy documents_read_by_type on public.documents
for select to authenticated
using ((select private.can_read_document(business_id,id)));

create policy document_items_read_by_parent on public.document_items
for select to authenticated
using ((select private.can_read_document(business_id,document_id)));

create policy document_events_read_by_parent on public.document_events
for select to authenticated
using ((select private.can_read_document(business_id,document_id)));

create policy invoice_sequences_read_by_type on public.invoice_number_sequences
for select to authenticated
using (
  (document_type in ('sale','service_sale','sales_return')
   and (select private.has_business_permission(business_id,'sales.read')))
  or
  (document_type in ('purchase','purchase_return')
   and (select private.has_business_permission(business_id,'purchases.read')))
);

create policy file_attachments_read_by_entity on public.file_attachments
for select to authenticated
using (
  case
    when entity_type in ('sale','service_sale','sales_return','purchase','purchase_return')
      then (select private.can_read_document(business_id,entity_id))
    when entity_type='cheque'
      then (select private.has_business_permission(business_id,'cheques.read'))
       and exists (select 1 from public.cheques c where c.business_id=file_attachments.business_id and c.id=file_attachments.entity_id)
    when entity_type in ('expense','other_income','wastage')
      then (select private.has_business_permission(business_id,'expenses.read'))
    else (select private.has_business_permission(business_id,'settings.manage'))
  end
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
      ('financial_accounts','payments.read'),
      ('account_transfers','payments.read'),
      ('financial_transactions','payments.read'),
      ('transaction_allocations','payments.read'),
      ('transaction_allocation_reversals','payments.read'),
      ('business_bank_details','invoice.settings.read'),
      ('invoice_design_presets','invoice.settings.read'),
      ('cheques','cheques.read'),
      ('cheque_events','cheques.read'),
      ('cheque_assignments','cheques.read'),
      ('cheque_assignment_events','cheques.read'),
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
    ('admin','payments.create'),('admin','payments.receive.create'),('admin','payments.pay.create'),('admin','cheques.read'),('admin','cheques.update_status'),('admin','inventory.read'),
    ('admin','inventory.adjust'),('admin','inventory.transfer'),('admin','expenses.read'),('admin','expenses.create'),
    ('admin','reports.basic.read'),('admin','reports.profit.read'),('admin','settings.manage'),('admin','members.read'),
    ('admin','members.manage'),('admin','audit.read'),('admin','accounting.ledger.read'),('admin','accounting.journal.post'),('admin','settings.read'),('admin','invoice.settings.read'),
    ('accountant','contacts.read'),('accountant','contacts.write'),('accountant','catalog.read'),('accountant','catalog.cost.read'),
    ('accountant','sales.read'),('accountant','sales.create'),('accountant','sales.edit_draft'),('accountant','sales.post'),
    ('accountant','purchases.read'),('accountant','purchases.create'),('accountant','payments.read'),('accountant','payments.create'),('accountant','payments.receive.create'),('accountant','payments.pay.create'),
    ('accountant','cheques.read'),('accountant','cheques.update_status'),('accountant','inventory.read'),
    ('accountant','expenses.read'),('accountant','expenses.create'),('accountant','reports.basic.read'),
    ('accountant','reports.profit.read'),('accountant','audit.read'),('accountant','accounting.ledger.read'),('accountant','accounting.journal.post'),('accountant','settings.read'),('accountant','invoice.settings.read'),
    ('sales','contacts.read'),('sales','contacts.write'),('sales','catalog.read'),('sales','sales.read'),
    ('sales','sales.create'),('sales','sales.edit_draft'),('sales','sales.post'),('sales','inventory.read'),('sales','payments.receive.create'),
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
    (v_business_id,'sale','',1,6,'never'),
    (v_business_id,'service_sale','',1,6,'never'),
    (v_business_id,'purchase','',1,6,'never'),
    (v_business_id,'sales_return','',1,6,'never'),
    (v_business_id,'purchase_return','',1,6,'never'),
    (v_business_id,'expense','',1,6,'never'),
    (v_business_id,'other_income','',1,6,'never'),
    (v_business_id,'wastage','',1,6,'never'),
    (v_business_id,'opening_balance','',1,6,'never'),
    (v_business_id,'adjustment','',1,6,'never');

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
  if p_document_type not in ('sale','service_sale','purchase','sales_return','purchase_return','expense','other_income','wastage','opening_balance','adjustment') then
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
  if p_document_type in ('expense','other_income','wastage')
     and not (select private.has_business_permission(p_business_id,'expenses.create')) then
    raise exception 'not_authorized' using errcode='42501';
  end if;
  if p_document_type in ('opening_balance','adjustment')
     and not (select private.has_business_permission(p_business_id,'accounting.journal.post')) then
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
revoke all on function private.next_document_number(uuid,text,uuid) from public,anon,authenticated;

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
  v_document_allocated bigint;
  v_id uuid;
begin
  if auth.uid() is null or not (select private.is_business_member(p_business_id)) then
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

  if v_doc.document_type in ('sale','service_sale') then
    if not (select private.has_business_permission(p_business_id,'payments.receive.create'))
       or v_tx.transaction_type <> 'receipt' then
      raise exception 'receipt_allocation_not_authorized' using errcode='42501';
    end if;
  elsif v_doc.document_type='purchase' then
    if not (select private.has_business_permission(p_business_id,'payments.pay.create'))
       or v_tx.transaction_type not in ('supplier_payment','payment') then
      raise exception 'supplier_payment_allocation_not_authorized' using errcode='42501';
    end if;
  else
    raise exception 'document_type_not_allocatable' using errcode='22023';
  end if;

  if v_tx.contact_id is not null and v_doc.contact_id is not null
     and v_tx.contact_id <> v_doc.contact_id then
    raise exception 'contact_mismatch' using errcode='22023';
  end if;
  if v_tx.currency_code <> v_doc.currency_code then
    raise exception 'currency_mismatch' using errcode='22023';
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

  select coalesce(sum(a.allocated_amount),0)-coalesce((
    select sum(r.reversed_amount)
    from public.transaction_allocation_reversals r
    join public.transaction_allocations ar on ar.business_id=r.business_id and ar.id=r.allocation_id
    where ar.business_id=p_business_id and ar.document_id=p_document_id
  ),0) into v_document_allocated
  from public.transaction_allocations a
  where a.business_id=p_business_id and a.document_id=p_document_id;

  if v_document_allocated + p_amount > v_doc.total_amount then
    raise exception 'allocation_exceeds_document_balance' using errcode='23514';
  end if;

  insert into public.transaction_allocations(business_id,transaction_id,document_id,allocated_amount,created_by)
  values(p_business_id,p_transaction_id,p_document_id,p_amount,auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function private.allocate_payment(uuid,uuid,uuid,bigint) from public,anon;
grant execute on function private.allocate_payment(uuid,uuid,uuid,bigint) to authenticated;



create or replace function private.get_business_entitlements(p_business_id uuid)
returns table(feature_code text,enabled boolean,limit_value bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select e.feature_code,e.enabled,e.limit_value
  from (
    select be.feature_code,be.enabled,be.limit_value,
           row_number() over (
             partition by be.feature_code
             order by be.priority desc,be.valid_from desc,be.created_at desc
           ) as rn
    from public.business_entitlements be
    where be.business_id=p_business_id
      and be.valid_from <= now()
      and (be.valid_until is null or be.valid_until > now())
      and (select private.is_business_member(p_business_id))
  ) e
  where e.rn=1;
$$;
revoke all on function private.get_business_entitlements(uuid) from public,anon;
grant execute on function private.get_business_entitlements(uuid) to authenticated;

create or replace function public.get_business_entitlements(p_business_id uuid)
returns table(feature_code text,enabled boolean,limit_value bigint)
language sql
stable
security invoker
set search_path = ''
as $$ select * from private.get_business_entitlements(p_business_id); $$;
revoke all on function public.get_business_entitlements(uuid) from public,anon;
grant execute on function public.get_business_entitlements(uuid) to authenticated;

create or replace function private.assert_feature_limit(
  p_business_id uuid,
  p_feature_code text,
  p_requested_count bigint
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_enabled boolean; v_limit bigint;
begin
  if auth.uid() is null or not (select private.is_business_member(p_business_id)) then
    raise exception 'not_authorized' using errcode='42501';
  end if;
  if p_requested_count is null or p_requested_count < 0 then
    raise exception 'invalid_requested_count' using errcode='22023';
  end if;
  select enabled,limit_value into v_enabled,v_limit
  from public.business_entitlements
  where business_id=p_business_id
    and feature_code=p_feature_code
    and valid_from <= now()
    and (valid_until is null or valid_until > now())
  order by priority desc,valid_from desc,created_at desc
  limit 1;
  if not found or not v_enabled then
    raise exception 'feature_not_enabled' using errcode='23514';
  end if;
  if v_limit is not null and p_requested_count > v_limit then
    raise exception 'feature_limit_reached' using errcode='23514';
  end if;
end;
$$;
revoke all on function private.assert_feature_limit(uuid,text,bigint) from public,anon,authenticated;


create or replace function private.create_document_draft(
  p_business_id uuid,
  p_document_type text,
  p_contact_id uuid,
  p_warehouse_id uuid,
  p_fiscal_period_id uuid,
  p_document_date date,
  p_due_date date,
  p_notes text,
  p_discount_amount bigint,
  p_tax_rate numeric(8,4),
  p_items jsonb,
  p_idempotency_key uuid
)
returns table(document_id uuid,document_number text,version bigint)
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_user_id uuid := auth.uid();
  v_existing_id uuid;
  v_existing_number text;
  v_existing_version bigint;
  v_existing_type text;
  v_number text;
  v_warehouse_id uuid := p_warehouse_id;
  v_currency_code text;
  v_tax_enabled boolean;
  v_default_tax_rate numeric(8,4);
  v_tax_rate numeric(8,4);
  v_doc_discount bigint := coalesce(p_discount_amount,0);
  v_subtotal bigint := 0;
  v_item_discount_total bigint := 0;
  v_total_net bigint := 0;
  v_total_discount bigint := 0;
  v_taxable bigint := 0;
  v_tax bigint := 0;
  v_total bigint := 0;
  v_item_count integer;
  v_item jsonb;
  v_normalized_items jsonb := '[]'::jsonb;
  v_item_type text;
  v_product_id uuid;
  v_service_id uuid;
  v_description text;
  v_unit_name text;
  v_default_price bigint;
  v_unit_price bigint;
  v_quantity numeric(20,4);
  v_item_discount bigint;
  v_base_amount bigint;
  v_line_net bigint;
  v_doc_discount_share bigint;
  v_line_taxable bigint;
  v_line_tax bigint;
  v_line_total bigint;
  v_allocated_doc_discount bigint := 0;
  v_allocated_tax bigint := 0;
  v_ord bigint;
  v_period_start date;
  v_period_end date;
  v_period_status text;
  v_doc_id uuid;
begin
  if v_user_id is null or not (select private.is_business_member(p_business_id)) then
    raise exception 'not_authorized' using errcode='42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'idempotency_key_required' using errcode='22023';
  end if;
  if p_document_date is null or p_due_date is not null and p_due_date < p_document_date then
    raise exception 'invalid_document_dates' using errcode='22023';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then
    raise exception 'document_items_required' using errcode='22023';
  end if;

  if p_document_type in ('sale','service_sale') then
    if not (select private.has_business_permission(p_business_id,'sales.create')) then
      raise exception 'not_authorized' using errcode='42501';
    end if;
  elsif p_document_type='purchase' then
    if not (select private.has_business_permission(p_business_id,'purchases.create')) then
      raise exception 'not_authorized' using errcode='42501';
    end if;
  else
    raise exception 'unsupported_draft_document_type' using errcode='22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_business_id::text || ':' || p_idempotency_key::text,0)
  );

  select d.id,d.document_number,d.version,d.document_type
    into v_existing_id,v_existing_number,v_existing_version,v_existing_type
  from public.documents d
  where d.business_id=p_business_id and d.idempotency_key=p_idempotency_key
  for update;
  if found then
    if v_existing_type <> p_document_type then
      raise exception 'idempotency_key_payload_conflict' using errcode='23505';
    end if;
    return query select v_existing_id,v_existing_number,v_existing_version;
    return;
  end if;

  select bs.currency_code,bs.tax_enabled,bs.default_tax_rate
    into v_currency_code,v_tax_enabled,v_default_tax_rate
  from public.business_settings bs
  where bs.business_id=p_business_id;
  if not found then
    raise exception 'business_settings_missing' using errcode='P0002';
  end if;

  if coalesce(v_tax_enabled,false) then
    if (select private.has_business_permission(p_business_id,'settings.manage'))
       and p_tax_rate is not null then
      v_tax_rate:=p_tax_rate;
    else
      v_tax_rate:=coalesce(v_default_tax_rate,0);
    end if;
  else
    v_tax_rate:=0;
  end if;
  if v_tax_rate < 0 or v_tax_rate > 100 then
    raise exception 'invalid_tax_rate' using errcode='22023';
  end if;

  if p_document_type in ('sale','purchase') and v_warehouse_id is null then
    select default_warehouse_id into v_warehouse_id
    from public.business_inventory_settings
    where business_id=p_business_id;
    if v_warehouse_id is null then
      raise exception 'default_warehouse_not_configured' using errcode='P0002';
    end if;
  end if;

  if p_fiscal_period_id is not null then
    select fp.start_date,fp.end_date,fp.status
      into v_period_start,v_period_end,v_period_status
    from public.fiscal_periods fp
    where fp.business_id=p_business_id and fp.id=p_fiscal_period_id
    for share;
    if not found or v_period_status not in ('open','reopened')
       or p_document_date < v_period_start or p_document_date > v_period_end then
      raise exception 'invalid_or_closed_fiscal_period' using errcode='23514';
    end if;
  end if;

  v_item_count:=jsonb_array_length(p_items);
  if p_document_type in ('sale','service_sale') then
    perform private.assert_feature_limit(p_business_id,'invoice.items.limit',v_item_count);
  end if;

  for v_item in select value from jsonb_array_elements(p_items) as x(value)
  loop
    v_item_type:=v_item->>'item_type';
    v_product_id:=nullif(v_item->>'product_id','')::uuid;
    v_service_id:=nullif(v_item->>'service_id','')::uuid;
    v_description:=null;
    v_unit_name:=null;
    v_default_price:=null;

    if p_document_type in ('sale','purchase') and v_item_type='product' then
      if v_product_id is null or v_service_id is not null then
        raise exception 'invalid_product_line' using errcode='22023';
      end if;
      select p.name,p.unit_name,p.sale_price
        into v_description,v_unit_name,v_default_price
      from public.products p
      where p.business_id=p_business_id and p.id=v_product_id and p.is_active;
      if not found then
        raise exception 'product_not_found_or_inactive' using errcode='P0002';
      end if;
      if p_document_type='purchase' then v_default_price:=null; end if;
    elsif p_document_type='service_sale' and v_item_type='service' then
      if v_service_id is null or v_product_id is not null then
        raise exception 'invalid_service_line' using errcode='22023';
      end if;
      select sv.name,sv.default_price
        into v_description,v_default_price
      from public.services sv
      where sv.business_id=p_business_id and sv.id=v_service_id and sv.is_active;
      if not found then
        raise exception 'service_not_found_or_inactive' using errcode='P0002';
      end if;
      v_unit_name:='خدمت';
    elsif v_item_type='free_text' and v_product_id is null and v_service_id is null then
      v_description:=nullif(trim(v_item->>'description'),'');
      v_unit_name:=coalesce(nullif(trim(v_item->>'unit_name'),''),'عدد');
      if v_description is null then
        raise exception 'free_text_description_required' using errcode='22023';
      end if;
    else
      raise exception 'item_type_not_allowed_for_document' using errcode='22023';
    end if;

    v_quantity:=nullif(v_item->>'quantity','')::numeric;
    v_unit_price:=coalesce(nullif(v_item->>'unit_price','')::bigint,v_default_price);
    v_item_discount:=coalesce(nullif(v_item->>'discount_amount','')::bigint,0);
    if v_quantity is null or v_quantity <= 0 or v_unit_price is null or v_unit_price < 0 or v_item_discount < 0 then
      raise exception 'invalid_document_item_values' using errcode='22023';
    end if;
    v_base_amount:=round(v_quantity*v_unit_price)::bigint;
    if v_item_discount > v_base_amount then
      raise exception 'item_discount_exceeds_line_amount' using errcode='23514';
    end if;

    v_subtotal:=v_subtotal+v_base_amount;
    v_item_discount_total:=v_item_discount_total+v_item_discount;
    v_total_net:=v_total_net+v_base_amount-v_item_discount;
    v_normalized_items:=v_normalized_items || jsonb_build_array(jsonb_build_object(
      'item_type',v_item_type,'product_id',v_product_id,'service_id',v_service_id,
      'description',v_description,'unit_name',v_unit_name,'quantity',v_quantity,
      'unit_price',v_unit_price,'item_discount',v_item_discount,'base_amount',v_base_amount
    ));
  end loop;

  if v_doc_discount < 0 or v_doc_discount > v_total_net then
    raise exception 'document_discount_exceeds_net_amount' using errcode='23514';
  end if;
  v_total_discount:=v_item_discount_total+v_doc_discount;
  v_taxable:=v_subtotal-v_total_discount;
  v_tax:=round(v_taxable*v_tax_rate/100)::bigint;
  v_total:=v_taxable+v_tax;

  v_number:=private.next_document_number(p_business_id,p_document_type,p_fiscal_period_id);
  insert into public.documents(
    business_id,document_type,document_number,fiscal_period_id,contact_id,warehouse_id,
    document_date,due_date,currency_code,status,subtotal,discount_amount,taxable_amount,
    tax_amount,total_amount,notes,idempotency_key,created_by
  ) values (
    p_business_id,p_document_type,v_number,p_fiscal_period_id,p_contact_id,v_warehouse_id,
    p_document_date,p_due_date,v_currency_code,'draft',v_subtotal,v_total_discount,v_taxable,
    v_tax,v_total,p_notes,p_idempotency_key,v_user_id
  ) returning id into v_doc_id;

  for v_item,v_ord in
    select value,ordinality from jsonb_array_elements(v_normalized_items) with ordinality as x(value,ordinality)
  loop
    v_line_net:=(v_item->>'base_amount')::bigint-(v_item->>'item_discount')::bigint;
    if v_total_net=0 then
      v_doc_discount_share:=0;
    elsif v_ord < v_item_count then
      v_doc_discount_share:=least(
        round(v_doc_discount::numeric*v_line_net/v_total_net)::bigint,
        v_doc_discount-v_allocated_doc_discount
      );
    else
      v_doc_discount_share:=v_doc_discount-v_allocated_doc_discount;
    end if;
    v_allocated_doc_discount:=v_allocated_doc_discount+v_doc_discount_share;
    v_line_taxable:=v_line_net-v_doc_discount_share;
    if v_ord < v_item_count then
      v_line_tax:=least(round(v_line_taxable*v_tax_rate/100)::bigint,v_tax-v_allocated_tax);
    else
      v_line_tax:=v_tax-v_allocated_tax;
    end if;
    v_allocated_tax:=v_allocated_tax+v_line_tax;
    v_line_total:=v_line_taxable+v_line_tax;

    insert into public.document_items(
      business_id,document_id,product_id,service_id,item_type,description_snapshot,
      quantity,unit_name_snapshot,unit_price,discount_amount,tax_rate_snapshot,tax_amount,
      line_total,sort_order
    ) values (
      p_business_id,v_doc_id,
      nullif(v_item->>'product_id','')::uuid,
      nullif(v_item->>'service_id','')::uuid,
      v_item->>'item_type',v_item->>'description',
      (v_item->>'quantity')::numeric,v_item->>'unit_name',
      (v_item->>'unit_price')::bigint,
      (v_item->>'item_discount')::bigint+v_doc_discount_share,
      v_tax_rate,v_line_tax,v_line_total,v_ord::integer
    );
  end loop;

  insert into public.document_events(
    business_id,document_id,event_type,old_status,new_status,event_payload,performed_by
  ) values (
    p_business_id,v_doc_id,'draft_created',null,'draft',
    jsonb_build_object('item_count',v_item_count,'idempotency_key',p_idempotency_key),v_user_id
  );

  return query select v_doc_id,v_number,1::bigint;
end;
$fn$;

revoke all on function private.create_document_draft(uuid,text,uuid,uuid,uuid,date,date,text,bigint,numeric,jsonb,uuid) from public,anon;
grant execute on function private.create_document_draft(uuid,text,uuid,uuid,uuid,date,date,text,bigint,numeric,jsonb,uuid) to authenticated;

create or replace function public.create_document_draft(
  p_business_id uuid,
  p_document_type text,
  p_contact_id uuid,
  p_warehouse_id uuid,
  p_fiscal_period_id uuid,
  p_document_date date,
  p_due_date date,
  p_notes text,
  p_discount_amount bigint,
  p_tax_rate numeric(8,4),
  p_items jsonb,
  p_idempotency_key uuid
)
returns table(document_id uuid,document_number text,version bigint)
language sql
security invoker
set search_path = ''
as $fn$
  select * from private.create_document_draft(
    p_business_id,p_document_type,p_contact_id,p_warehouse_id,p_fiscal_period_id,
    p_document_date,p_due_date,p_notes,p_discount_amount,p_tax_rate,p_items,p_idempotency_key
  );
$fn$;
revoke all on function public.create_document_draft(uuid,text,uuid,uuid,uuid,date,date,text,bigint,numeric,jsonb,uuid) from public,anon;
grant execute on function public.create_document_draft(uuid,text,uuid,uuid,uuid,date,date,text,bigint,numeric,jsonb,uuid) to authenticated;

create or replace function private.consume_feature_quota(
  p_business_id uuid,
  p_feature_code text,
  p_period_start date,
  p_idempotency_key uuid,
  p_source_id uuid default null
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enabled boolean;
  v_limit bigint;
  v_usage bigint;
  v_event_id uuid;
begin
  if auth.uid() is null
     or not (select private.is_business_member(p_business_id))
     or p_feature_code <> 'invoices.daily_limit'
     or not (select private.has_business_permission(p_business_id,'sales.create')) then
    raise exception 'feature_quota_not_authorized' using errcode='42501';
  end if;
  if p_period_start is null or p_idempotency_key is null then
    raise exception 'feature_quota_parameters_required' using errcode='22023';
  end if;

  select enabled,limit_value
    into v_enabled,v_limit
  from public.business_entitlements
  where business_id=p_business_id
    and feature_code=p_feature_code
    and valid_from <= now()
    and (valid_until is null or valid_until > now())
  order by priority desc,valid_from desc,created_at desc
  limit 1;

  if not found or not coalesce(v_enabled,false) then
    raise exception 'feature_not_enabled' using errcode='23514';
  end if;
  if v_limit is null then
    return null;
  end if;

  insert into private.feature_usage_events(
    business_id,feature_code,period_start,idempotency_key,source_id
  ) values (
    p_business_id,p_feature_code,p_period_start,p_idempotency_key,p_source_id
  )
  on conflict (business_id,feature_code,idempotency_key) do nothing
  returning id into v_event_id;

  if v_event_id is null then
    select usage_count into v_usage
    from private.feature_usage_counters
    where business_id=p_business_id and feature_code=p_feature_code and period_start=p_period_start;
    return coalesce(v_usage,0);
  end if;

  insert into private.feature_usage_counters as counter(business_id,feature_code,period_start,usage_count)
  values(p_business_id,p_feature_code,p_period_start,1)
  on conflict (business_id,feature_code,period_start)
  do update set usage_count=counter.usage_count+1,updated_at=now()
  where counter.usage_count < v_limit
  returning usage_count into v_usage;

  if not found then
    raise exception 'feature_daily_limit_reached' using errcode='23514';
  end if;
  return v_usage;
end;
$$;

revoke all on function private.consume_feature_quota(uuid,text,date,uuid,uuid) from public,anon,authenticated;

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
as $$
begin
  raise exception 'immutable_record: create a reversal or corrective record'
    using errcode='55000';
end;
$$;

create or replace function private.guard_posted_document()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status='posted' then
    raise exception 'posted_document_immutable' using errcode='55000';
  end if;
  if tg_op='DELETE' then return old; else return new; end if;
end;
$$;

create or replace function private.guard_document_item_parent()
returns trigger
language plpgsql
set search_path = ''
as $$
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
  if tg_op='DELETE' then return old; else return new; end if;
end;
$$;

create or replace function private.guard_posted_journal_entry()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status in ('posted','reversed') then
    raise exception 'posted_journal_entry_immutable' using errcode='55000';
  end if;
  if tg_op='DELETE' then return old; else return new; end if;
end;
$$;

create or replace function private.guard_journal_line_parent()
returns trigger
language plpgsql
set search_path = ''
as $$
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
  if tg_op='DELETE' then return old; else return new; end if;
end;
$$;

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

create trigger cheque_assignment_events_append_only
before update or delete on public.cheque_assignment_events
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

create trigger feature_usage_events_append_only
before update or delete on private.feature_usage_events
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
as $$
begin
  if old.status in ('posted','reversed') then
    raise exception 'posted_financial_transaction_immutable' using errcode='55000';
  end if;
  if tg_op='DELETE' then return old; else return new; end if;
end;
$$;


revoke all on function private.reject_immutable_mutation() from public,anon,authenticated;
revoke all on function private.guard_posted_document() from public,anon,authenticated;
revoke all on function private.guard_document_item_parent() from public,anon,authenticated;
revoke all on function private.guard_posted_journal_entry() from public,anon,authenticated;
revoke all on function private.guard_journal_line_parent() from public,anon,authenticated;
revoke all on function private.guard_posted_financial_transaction() from public,anon,authenticated;
revoke all on function private.consume_feature_quota(uuid,text,date,uuid,uuid) from public,anon,authenticated;

create trigger financial_transactions_posted_immutable
before update or delete on public.financial_transactions
for each row execute function private.guard_posted_financial_transaction();

-- Public invoker wrappers are the only client-facing entry points for these private routines.
create or replace function public.create_business(p_name text)
returns uuid
language sql
security invoker
set search_path = ''
as $$ select private.create_business(p_name); $$;

create or replace function public.allocate_payment(
  p_business_id uuid,p_transaction_id uuid,p_document_id uuid,p_amount bigint
)
returns uuid
language sql
security invoker
set search_path = ''
as $$ select private.allocate_payment(p_business_id,p_transaction_id,p_document_id,p_amount); $$;

create or replace function public.post_journal_entry(p_business_id uuid,p_entry_id uuid)
returns void
language sql
security invoker
set search_path = ''
as $$ select private.post_journal_entry(p_business_id,p_entry_id); $$;

revoke all on function public.create_business(text) from public,anon;
revoke all on function public.allocate_payment(uuid,uuid,uuid,bigint) from public,anon;
revoke all on function public.post_journal_entry(uuid,uuid) from public,anon;
grant execute on function public.create_business(text) to authenticated;
grant execute on function public.allocate_payment(uuid,uuid,uuid,bigint) to authenticated;
grant execute on function public.post_journal_entry(uuid,uuid) to authenticated;

-- Profiles are self-editable only for non-authoritative presentation fields.
grant update(display_name,phone,avatar_path) on public.profiles to authenticated;



create or replace function private.guard_posted_status_record()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if coalesce(to_jsonb(old)->>'status','') in ('posted','reversed') then
    raise exception 'posted_record_immutable: create a reversal'
      using errcode='55000';
  end if;
  if tg_op='DELETE' then return old; else return new; end if;
end;
$$;

create or replace function private.guard_stock_transfer_item_parent()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_business_id uuid; v_transfer_id uuid; v_status text;
begin
  if tg_op='DELETE' then
    v_business_id:=old.business_id; v_transfer_id:=old.transfer_id;
  else
    v_business_id:=new.business_id; v_transfer_id:=new.transfer_id;
  end if;
  select status into v_status from public.stock_transfers
  where business_id=v_business_id and id=v_transfer_id;
  if v_status in ('posted','reversed') then
    raise exception 'posted_stock_transfer_items_immutable' using errcode='55000';
  end if;
  if tg_op='DELETE' then return old; else return new; end if;
end;
$$;

revoke all on function private.guard_posted_status_record() from public,anon,authenticated;
revoke all on function private.guard_stock_transfer_item_parent() from public,anon,authenticated;

create trigger account_transfers_posted_immutable
before update or delete on public.account_transfers
for each row execute function private.guard_posted_status_record();

create trigger stock_transfers_posted_immutable
before update or delete on public.stock_transfers
for each row execute function private.guard_posted_status_record();

create trigger cheque_assignments_posted_immutable
before update or delete on public.cheque_assignments
for each row execute function private.guard_posted_status_record();

create trigger stock_transfer_items_posted_immutable
before insert or update or delete on public.stock_transfer_items
for each row execute function private.guard_stock_transfer_item_parent();


commit;
