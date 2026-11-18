-- Read-only legacy normalization preflight contract.
-- Requires migrations 001-014 and runs in the disposable PostgreSQL CI database.
begin;

-- The minimal CI Auth shim omits this Supabase users column by default.
alter table auth.users add column if not exists raw_user_meta_data jsonb not null default '{}'::jsonb;

do $static$
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
end $static$;

-- Runtime contract: authorized owner can inspect a tenant-scoped fixture,
-- orphan references are counted, and the RPC never mutates source or targets.
do $runtime$
declare
  v_owner uuid := '81000000-0000-4000-8000-000000000001';
  v_business uuid := '82000000-0000-4000-8000-000000000001';
  v_other_business uuid := '82000000-0000-4000-8000-000000000002';
  v_clean_business uuid := '82000000-0000-4000-8000-000000000003';
  v_report jsonb;
  v_before bigint;
  v_after bigint;
begin
  insert into auth.users(id,email,email_confirmed_at)
  values(v_owner,'legacy-preflight-owner@example.test',now())
  on conflict(id) do nothing;

  insert into public.businesses(id,name,owner_user_id)
  values
    (v_business,'Legacy preflight fixture',v_owner),
    (v_other_business,'Isolated business fixture',v_owner),
    (v_clean_business,'Clean legacy fixture',v_owner)
  on conflict(id) do nothing;

  insert into public.business_members(business_id,user_id,role_code,status)
  values
    (v_business,v_owner,'owner','active'),
    (v_other_business,v_owner,'owner','active'),
    (v_clean_business,v_owner,'owner','active')
  on conflict(business_id,user_id) do update set role_code='owner',status='active';

  insert into private.business_state_records(business_id,collection,legacy_id,payload_public)
  values
    (v_business,'cust','cust-1','{"id":"cust-1","n":"Customer"}'::jsonb),
    (v_business,'prod','prod-1','{"id":"prod-1","n":"Product"}'::jsonb),
    (v_business,'inv','inv-1','{"id":"inv-1","cid":"missing-customer","items":[{"pid":"missing-product"}]}'::jsonb),
    (v_business,'categories','value:دسته اصلی','{"value":"دسته اصلی"}'::jsonb),
    (v_business,'services','value:نصب','{"value":"نصب"}'::jsonb)
  on conflict(business_id,collection,legacy_id) do update
    set payload_public=excluded.payload_public,deleted_at=null;

  select count(*) into v_before from private.business_state_records
  where business_id=v_business;

  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  v_report:=public.preview_legacy_normalization(v_business);

  if v_report->>'mode'<>'read_only_preflight'
    or (v_report->>'orphan_invoice_customers')::bigint<>1
    or (v_report->>'orphan_invoice_products')::bigint<>1
    or (v_report->>'safe_to_import')::boolean is not false then
    raise exception 'Preflight did not report expected orphan references: %',v_report;
  end if;

  select count(*) into v_after from private.business_state_records
  where business_id=v_business;
  if v_after<>v_before then
    raise exception 'Preflight must not mutate legacy source records';
  end if;

  if (select (value->>'missing_payload_ids')::bigint
      from jsonb_array_elements(v_report->'collections') where value->>'collection'='categories')<>0
    or (select (value->>'payload_id_mismatches')::bigint
      from jsonb_array_elements(v_report->'collections') where value->>'collection'='categories')<>0
    or (select (value->>'missing_payload_ids')::bigint
      from jsonb_array_elements(v_report->'collections') where value->>'collection'='services')<>0
    or (select (value->>'payload_id_mismatches')::bigint
      from jsonb_array_elements(v_report->'collections') where value->>'collection'='services')<>0 then
    raise exception 'String-based categories/services must validate through their value: legacy identity';
  end if;

  insert into private.business_state_records(business_id,collection,legacy_id,payload_public)
  values
    (v_clean_business,'cust','clean-customer','{"id":"clean-customer","n":"Clean Customer"}'::jsonb),
    (v_clean_business,'prod','clean-product','{"id":"clean-product","n":"Clean Product"}'::jsonb),
    (v_clean_business,'categories','value:دسته تمیز','{"value":"دسته تمیز"}'::jsonb),
    (v_clean_business,'services','value:خدمت تمیز','{"value":"خدمت تمیز"}'::jsonb);
  v_report:=public.preview_legacy_normalization(v_clean_business);
  if (v_report->>'safe_to_import')::boolean is not true then
    raise exception 'Valid primitive categories and services must not block preflight: %',v_report;
  end if;

  if exists(select 1 from public.contacts where business_id=v_business)
    or exists(select 1 from public.products where business_id=v_business)
    or exists(select 1 from public.documents where business_id=v_business) then
    raise exception 'Preflight must not create normalized records';
  end if;

  v_report:=public.preview_legacy_normalization(v_other_business);
  if (select coalesce(sum((value->>'total')::bigint),0)
      from jsonb_array_elements(v_report->'collections'))<>0
    or (v_report->>'orphan_invoice_customers')::bigint<>0
    or (v_report->>'orphan_invoice_products')::bigint<>0 then
    raise exception 'Preflight leaked legacy records across business boundaries';
  end if;
end;
$runtime$;

rollback;
