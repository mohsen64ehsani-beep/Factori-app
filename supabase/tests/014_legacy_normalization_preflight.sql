-- Read-only legacy normalization preflight contract.
-- Requires migrations 001-014 and runs in the disposable PostgreSQL CI database.
begin;
do $$
declare v_def text;
begin
 if to_regprocedure('public.preview_legacy_normalization(uuid)') is null then
  raise exception 'Legacy preflight RPC is missing';
 end if;
 if not has_function_privilege('authenticated','public.preview_legacy_normalization(uuid)','EXECUTE') then
  raise exception 'Authenticated users must be able to run authorized preflight';
 end if;
 if has_function_privilege('anon','public.preview_legacy_normalization(uuid)','EXECUTE') then
  raise exception 'anon must not execute legacy preflight';
 end if;
 select pg_get_functiondef('public.preview_legacy_normalization(uuid)'::regprocedure) into v_def;
 if position('business.settings.manage' in v_def)=0
  or position('read_only_preflight' in v_def)=0
  or position('orphan_invoice_customers' in v_def)=0
  or position('orphan_invoice_products' in v_def)=0
  or position('financial_collections_deferred' in v_def)=0 then
  raise exception 'Preflight permission, reconciliation, or deferred-collection contract is incomplete';
 end if;
 if position('insert into public.' in lower(v_def))>0
  or position('update public.' in lower(v_def))>0
  or position('delete from public.' in lower(v_def))>0
  or position('insert into private.' in lower(v_def))>0
  or position('update private.' in lower(v_def))>0
  or position('delete from private.' in lower(v_def))>0 then
  raise exception 'Preflight RPC must remain read-only';
 end if;
 if position('payload_private' in v_def)>0 then
  raise exception 'Preflight must not expose or inspect protected payload values';
 end if;
end $$;
rollback;
