-- 028: Reconciliation reports counts only and remains tenant-scoped/read-only.
begin;

do $test$
declare
 v_owner uuid:='a7000000-0000-4000-8000-000000000001';
 v_outsider uuid:='a7000000-0000-4000-8000-000000000002';
 v_business uuid:='a8000000-0000-4000-8000-000000000001';
 v_other_business uuid:='a8000000-0000-4000-8000-000000000002';
 v_result jsonb;
 v_before bigint;
 v_after bigint;
 v_failed boolean:=false;
begin
 insert into auth.users(id,email,email_confirmed_at)
 values(v_owner,'legacy-reconcile-owner@example.test',now()),(v_outsider,'legacy-reconcile-outsider@example.test',now())
 on conflict(id) do nothing;
 insert into public.businesses(id,name,owner_user_id)
 values(v_business,'Reconcile business',v_owner),(v_other_business,'Other reconcile business',v_outsider)
 on conflict(id) do nothing;
 insert into public.business_members(business_id,user_id,role_code,status,joined_at)
 values(v_business,v_owner,'owner','active',now()),(v_other_business,v_owner,'owner','active',now())
 on conflict(business_id,user_id) do nothing;

 insert into private.business_state_records(business_id,collection,legacy_id,payload_public,payload_private,updated_by)
 values
  (v_business,'cust','reconcile-customer','{"id":"reconcile-customer","n":"Private customer name"}','{"secret":"never return"}',v_owner),
  (v_business,'prod','reconcile-product','{"id":"reconcile-product","n":"Product"}','{"buy":999}',v_owner),
  (v_business,'pay','reconcile-payment','{"id":"reconcile-payment","amt":100}','{}',v_owner);

 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_result:=public.import_legacy_reference_data(v_business,'a9000000-0000-4000-8000-000000000001');
 if (v_result->>'imported_customers')::integer<>1
  or (v_result->>'imported_products')::integer<>1 then
  raise exception 'Reconciliation fixture reference import failed: %',v_result;
 end if;
 update private.business_state_records
 set payload_public=payload_public||'{"sell":2000}'::jsonb
 where business_id=v_business and collection='prod' and legacy_id='reconcile-product';

 select count(*) into v_before from private.business_state_records where business_id=v_business;
 v_result:=public.reconcile_legacy_normalization(v_business);
 select count(*) into v_after from private.business_state_records where business_id=v_business;
 if v_before<>v_after then raise exception 'Reconciliation must not mutate source rows'; end if;

 if (v_result->>'mode')<>'read_only_reconciliation'
  or (v_result->>'safe_to_cutover')::boolean is not false
  or (v_result->>'deferred_financial_records')::bigint<>1
  or (v_result->>'unresolved_source_or_mapping_rows')::bigint<1 then
  raise exception 'Reconciliation did not report unresolved/deferred rows: %',v_result;
 end if;
 if position('Private customer name' in v_result::text)>0
  or position('never return' in v_result::text)>0
  or position('999' in v_result::text)>0 then
  raise exception 'Reconciliation must not expose customer or protected cost payloads';
 end if;
 if not exists(select 1 from jsonb_array_elements(v_result->'collections') as x(value)
   where value->>'collection'='prod' and (value->>'source_changed')::bigint=1) then
  raise exception 'Changed source fingerprint was not identified';
 end if;

 perform set_config('request.jwt.claim.sub',v_outsider::text,true);
 v_result:=public.reconcile_legacy_normalization(v_other_business);
 if (v_result->>'deferred_financial_records')::bigint<>0
  or (v_result->>'unresolved_source_or_mapping_rows')::bigint<>0 then
  raise exception 'Reconciliation leaked data across business boundaries';
 end if;

 v_failed:=false;
 perform set_config('request.jwt.claim.sub',v_outsider::text,true);
 begin
  perform public.reconcile_legacy_normalization(v_business);
 exception when insufficient_privilege then v_failed:=true;
 end;
 if not v_failed then raise exception 'Cross-business reconciliation must be denied'; end if;
end;
$test$;

rollback;
