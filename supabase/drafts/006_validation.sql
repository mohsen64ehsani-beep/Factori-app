-- READ-ONLY validation queries for a disposable test database after applying the draft migrations.
-- This file intentionally contains SELECT statements only.

-- 1) Verify all public base tables have RLS enabled.
select n.nspname as schema_name,c.relname as table_name,c.relrowsecurity as rls_enabled
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind='r' and c.relrowsecurity is not true
order by c.relname;

-- 2) Verify no anonymous grants exist on business data tables.
select table_schema,table_name,privilege_type
from information_schema.role_table_grants
where grantee='anon' and table_schema in ('public','private')
order by table_schema,table_name,privilege_type;

-- 3) Verify sensitive cost tables are private and have RLS.
select n.nspname as schema_name,c.relname as table_name,c.relrowsecurity as rls_enabled
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='private' and c.relkind='r'
order by c.relname;

-- 4) Find SECURITY DEFINER functions outside the private schema.
select n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) as arguments
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where p.prosecdef and n.nspname not in ('private','auth')
order by n.nspname,p.proname;

-- 5) Find public views that are not SECURITY INVOKER.
select v.schemaname,v.viewname
from pg_views v
join pg_class c on c.oid=(quote_ident(v.schemaname)||'.'||quote_ident(v.viewname))::regclass
where v.schemaname='public'
  and (c.reloptions is null or not (c.reloptions @> array['security_invoker=true']));

-- 6) Cross-business FK audit: all FK edges involving business_id should include business_id.
-- Review any returned FK manually; not all single-column FKs are wrong (Auth profile references are expected).
select conrelid::regclass as source_table,conname,pg_get_constraintdef(oid) as definition
from pg_constraint
where contype='f'
  and connamespace='public'::regnamespace
  and pg_get_constraintdef(oid) ilike '%business_id%'
order by source_table::text,conname;

-- 7) Check posted journal entries are balanced.
select e.business_id,e.id,e.entry_number,
       coalesce(sum(l.debit),0) as total_debit,
       coalesce(sum(l.credit),0) as total_credit
from public.journal_entries e
left join public.journal_lines l
  on l.business_id=e.business_id and l.journal_entry_id=e.id
where e.status='posted'
group by e.business_id,e.id,e.entry_number
having coalesce(sum(l.debit),0) <> coalesce(sum(l.credit),0);

-- 8) Check stock projection against the movement ledger (quantity only; cost is private).
select b.business_id,b.warehouse_id,b.product_id,b.quantity_on_hand,
       coalesce(sum(m.quantity_delta),0) as ledger_quantity
from public.warehouse_stock_balances b
left join public.stock_movements m
  on m.business_id=b.business_id and m.warehouse_id=b.warehouse_id and m.product_id=b.product_id
group by b.business_id,b.warehouse_id,b.product_id,b.quantity_on_hand
having b.quantity_on_hand <> coalesce(sum(m.quantity_delta),0);

-- 9) Find payment allocations that exceed source transaction amounts.
select t.business_id,t.id,t.amount,
  (select coalesce(sum(a.allocated_amount),0)
   from public.transaction_allocations a
   where a.business_id=t.business_id and a.transaction_id=t.id)
  -
  (select coalesce(sum(r.reversed_amount),0)
   from public.transaction_allocation_reversals r
   join public.transaction_allocations a
     on a.business_id=r.business_id and a.id=r.allocation_id
   where a.business_id=t.business_id and a.transaction_id=t.id) as net_allocated
from public.financial_transactions t
where
  (select coalesce(sum(a.allocated_amount),0)
   from public.transaction_allocations a
   where a.business_id=t.business_id and a.transaction_id=t.id)
  -
  (select coalesce(sum(r.reversed_amount),0)
   from public.transaction_allocation_reversals r
   join public.transaction_allocations a
     on a.business_id=r.business_id and a.id=r.allocation_id
   where a.business_id=t.business_id and a.transaction_id=t.id) > t.amount;

-- 9b) Find documents whose net allocated receipts exceed their total amount.
select d.business_id,d.id,d.total_amount,
  (select coalesce(sum(a.allocated_amount),0)
   from public.transaction_allocations a
   where a.business_id=d.business_id and a.document_id=d.id)
  -
  (select coalesce(sum(r.reversed_amount),0)
   from public.transaction_allocation_reversals r
   join public.transaction_allocations a
     on a.business_id=r.business_id and a.id=r.allocation_id
   where a.business_id=d.business_id and a.document_id=d.id) as net_allocated
from public.documents d
where
  (select coalesce(sum(a.allocated_amount),0)
   from public.transaction_allocations a
   where a.business_id=d.business_id and a.document_id=d.id)
  -
  (select coalesce(sum(r.reversed_amount),0)
   from public.transaction_allocation_reversals r
   join public.transaction_allocations a
     on a.business_id=r.business_id and a.id=r.allocation_id
   where a.business_id=d.business_id and a.document_id=d.id) > d.total_amount;

-- 10) Confirm invoice numbers are unique within business/type/period (including NULL periods).
select business_id,document_type,fiscal_period_id,document_number,count(*)
from public.documents
group by business_id,document_type,fiscal_period_id,document_number
having count(*) > 1;

-- 11) Confirm no private cost table is granted to anon/authenticated.
select table_schema,table_name,grantee,privilege_type
from information_schema.role_table_grants
where table_schema='private' and grantee in ('anon','authenticated')
order by table_name,grantee,privilege_type;
