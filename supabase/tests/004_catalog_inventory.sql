-- Disposable checks for migration 004. Run after 001-004 in isolated staging.
begin;
do $$
declare t text; r record;
begin
 foreach t in array array[
  'product_categories','products','product_costs','services','document_item_costs',
  'stock_movements','stock_transfers','stock_transfer_items','inventory_cost_layers','inventory_cost_allocations'
 ] loop
  if to_regclass('public.'||t) is null then raise exception 'Missing public.%',t; end if;
  select c.relrowsecurity into r from pg_class c where c.oid=to_regclass('public.'||t);
  if not r.relrowsecurity then raise exception 'RLS disabled on public.%',t; end if;
  if has_table_privilege('anon','public.'||t,'SELECT') then raise exception 'anon has SELECT on public.%',t; end if;
  if has_table_privilege('authenticated','public.'||t,'INSERT') then raise exception 'authenticated has direct INSERT on public.%',t; end if;
  if has_table_privilege('authenticated','public.'||t,'UPDATE') then raise exception 'authenticated has direct UPDATE on public.%',t; end if;
  if has_table_privilege('authenticated','public.'||t,'DELETE') then raise exception 'authenticated has direct DELETE on public.%',t; end if;
 end loop;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='product_costs' and policyname='product_costs_read') then
  raise exception 'Cost read policy missing';
 end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='products' and policyname='products_read') then
  raise exception 'Product read policy missing';
 end if;
end $$;
rollback;
