-- Disposable checks for migration 003. Run after 001-003 in isolated staging.
begin;
do $$
declare t text; r record;
begin
 foreach t in array array[
  'financial_accounts','financial_transactions','transaction_allocations','cheques',
  'cheque_events','chart_of_accounts','journal_entries','journal_lines','contact_ledger_entries'
 ] loop
  if to_regclass('public.'||t) is null then raise exception 'Missing public.%',t; end if;
  select c.relrowsecurity into r from pg_class c where c.oid=to_regclass('public.'||t);
  if not r.relrowsecurity then raise exception 'RLS disabled on public.%',t; end if;
  if has_table_privilege('anon','public.'||t,'SELECT') then raise exception 'anon has SELECT on public.%',t; end if;
  if has_table_privilege('authenticated','public.'||t,'INSERT') then raise exception 'authenticated has direct INSERT on public.%',t; end if;
  if has_table_privilege('authenticated','public.'||t,'UPDATE') then raise exception 'authenticated has direct UPDATE on public.%',t; end if;
  if has_table_privilege('authenticated','public.'||t,'DELETE') then raise exception 'authenticated has direct DELETE on public.%',t; end if;
 end loop;
 if not exists(select 1 from pg_constraint where conrelid='public.journal_lines'::regclass and contype='c') then
  raise exception 'Journal debit/credit checks are missing';
 end if;
 if not exists(select 1 from pg_indexes where schemaname='public' and indexname='financial_accounts_one_default') then
  raise exception 'Single default financial account index is missing';
 end if;
end $$;
rollback;
