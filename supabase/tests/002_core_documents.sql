-- Disposable database checks for 002_core_documents.sql.
-- Run after migration 001 and 002 in an isolated Supabase/Postgres project.
begin;

do $$
declare
  t text;
  r record;
begin
  foreach t in array array['contacts','warehouses','fiscal_periods','documents','document_items'] loop
    if to_regclass('public.'||t) is null then raise exception 'Missing table public.%',t; end if;
    select c.relrowsecurity into r from pg_class c where c.oid=to_regclass('public.'||t);
    if not r.relrowsecurity then raise exception 'RLS disabled on public.%',t; end if;
    if has_table_privilege('anon','public.'||t,'SELECT') then raise exception 'anon has SELECT on public.%',t; end if;
    if has_table_privilege('authenticated','public.'||t,'INSERT') then raise exception 'authenticated has direct INSERT on public.%',t; end if;
    if has_table_privilege('authenticated','public.'||t,'UPDATE') then raise exception 'authenticated has direct UPDATE on public.%',t; end if;
    if has_table_privilege('authenticated','public.'||t,'DELETE') then raise exception 'authenticated has direct DELETE on public.%',t; end if;
  end loop;

  if not has_function_privilege(
    'authenticated',
    'public.create_document_draft(uuid,text,uuid,uuid,uuid,date,date,text,numeric,numeric,jsonb,text)',
    'EXECUTE'
  ) then raise exception 'authenticated cannot execute create_document_draft'; end if;

  if has_function_privilege(
    'anon',
    'public.create_document_draft(uuid,text,uuid,uuid,uuid,date,date,text,numeric,numeric,jsonb,text)',
    'EXECUTE'
  ) then raise exception 'anon unexpectedly can execute create_document_draft'; end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid='public.documents'::regclass and contype='f'
      and conname like '%contacts%'
  ) then raise exception 'documents contact tenant FK is missing'; end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid='public.document_items'::regclass and contype='f'
      and conname like '%documents%'
  ) then raise exception 'document_items tenant FK is missing'; end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='document_items'
      and column_name in ('unit_cost','unit_cost_snapshot','buy_price','cost_total')
  ) then raise exception 'Sensitive cost fields must not be exposed on document_items'; end if;
end $$;

rollback;
