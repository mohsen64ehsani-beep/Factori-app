-- Regression tests for account-bound perpetual license claims.
-- Requires the isolated CI license schema fixture created before migration 013.
begin;

-- Supabase Auth user rows expose raw_user_meta_data; add it to the minimal CI shim.
alter table auth.users add column if not exists raw_user_meta_data jsonb not null default '{}'::jsonb;

do $test$
declare
  v_owner uuid := '10000000-0000-4000-8000-000000000001';
  v_other uuid := '10000000-0000-4000-8000-000000000002';
  v_employee uuid := '10000000-0000-4000-8000-000000000003';
  v_business uuid := '20000000-0000-4000-8000-000000000001';
  v_other_business uuid := '20000000-0000-4000-8000-000000000002';
  v_license uuid := '30000000-0000-4000-8000-000000000001';
  v_other_license uuid := '30000000-0000-4000-8000-000000000002';
  v_key text := 'FACTOORI-TEST-KEY-0001';
  v_other_key text := 'FACTOORI-TEST-KEY-0002';
  v_hash text;
  v_result jsonb;
  i integer;
begin
  if not has_function_privilege('authenticated','public.claim_factori_license(text,uuid)','EXECUTE')
     or has_function_privilege('anon','public.claim_factori_license(text,uuid)','EXECUTE') then
    raise exception 'License claim RPC must be authenticated-only';
  end if;
  if has_table_privilege('authenticated','private.factori_license_entitlements','SELECT')
     or has_table_privilege('authenticated','private.factori_license_entitlement_events','SELECT')
     or has_function_privilege('authenticated','private.business_has_premium_entitlement(uuid)','EXECUTE') then
    raise exception 'Clients must not directly read or execute private entitlement internals';
  end if;

  insert into auth.users(id,email,email_confirmed_at) values
    (v_owner,'owner@example.test',now()),
    (v_other,'other@example.test',now()),
    (v_employee,'employee@example.test',now());

  insert into public.businesses(id,name,owner_user_id) values
    (v_business,'Owner business',v_owner),
    (v_other_business,'Other business',v_other);
  insert into public.business_members(business_id,user_id,role_code,status) values
    (v_business,v_owner,'owner','active'),
    (v_business,v_employee,'accountant','active'),
    (v_other_business,v_other,'owner','active');

  v_hash := encode(extensions.digest(convert_to(v_key,'UTF8'),'sha256'),'hex');
  insert into public.factori_license_keys(id,key_hash,status,payment_verified_at)
  values (v_license,v_hash,'unused',now());
  v_hash := encode(extensions.digest(convert_to(v_other_key,'UTF8'),'sha256'),'hex');
  insert into public.factori_license_keys(id,key_hash,status,payment_verified_at)
  values (v_other_license,v_hash,'unused',now());

  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  v_result := public.claim_factori_license(v_key,v_business);
  if not coalesce((v_result->>'ok')::boolean,false) then
    raise exception 'Owner claim should succeed';
  end if;

  v_result := public.get_business_entitlements(v_business);
  if v_result->>'plan_status'<>'premium' or (v_result->>'is_premium')::boolean is not true then
    raise exception 'Owner business should receive Premium entitlement';
  end if;

  -- Premium bypasses server-side per-record and daily Free limits.
  perform private.assert_feature_limit(v_business,'invoice.items.limit',100);
  for i in 1..5 loop
    perform private.consume_feature_quota(v_business,'invoices.daily_limit',current_date,gen_random_uuid());
  end loop;
  if exists (select 1 from public.business_feature_usage
      where business_id=v_business and feature_code='invoices.daily_limit' and usage_date=current_date) then
    raise exception 'Premium business must not consume Free daily quota';
  end if;

  -- Free accounts remain subject to the server-enforced limits.
  perform set_config('request.jwt.claim.sub',v_other::text,true);
  begin
    perform private.assert_feature_limit(v_other_business,'invoice.items.limit',11);
    raise exception 'Free business must retain the per-record limit';
  exception when sqlstate '54000' then null;
  end;
  begin
    for i in 1..4 loop
      perform private.consume_feature_quota(v_other_business,'invoices.daily_limit',current_date,gen_random_uuid());
    end loop;
    raise exception 'Free business must retain the daily quota';
  exception when sqlstate '54000' then null;
  end;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);

  -- Same account can claim idempotently on another device/session.
  v_result := public.claim_factori_license(v_key,v_business);
  if (v_result->>'already_claimed')::boolean is not true then
    raise exception 'Repeated claim by same owner/business must be idempotent';
  end if;

  -- A different account on the same handset must not inherit this entitlement.
  perform set_config('request.jwt.claim.sub',v_other::text,true);
  v_result := public.get_business_entitlements(v_other_business);
  if v_result->>'plan_status'<>'free' or (v_result->>'is_premium')::boolean is not false then
    raise exception 'Unrelated account must remain Free';
  end if;

  -- Employee membership can consume the business entitlement, but cannot claim it.
  perform set_config('request.jwt.claim.sub',v_employee::text,true);
  v_result := public.get_business_entitlements(v_business);
  if v_result->>'plan_status'<>'premium' then
    raise exception 'Authorized employee should inherit business plan';
  end if;
  begin
    perform public.claim_factori_license(v_other_key,v_business);
    raise exception 'Employee must not claim license for owner business';
  exception when insufficient_privilege then null;
  end;

  -- Another account cannot transfer or re-claim an already-owned license.
  perform set_config('request.jwt.claim.sub',v_other::text,true);
  begin
    perform public.claim_factori_license(v_key,v_other_business);
    raise exception 'Other account must not claim an existing license';
  exception when unique_violation then null;
  end;

  -- Revocation must immediately remove Premium from the effective entitlement.
  update public.factori_license_keys set status='revoked' where id=v_license;
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  v_result := public.get_business_entitlements(v_business);
  if v_result->>'plan_status'<>'free' or (v_result->>'is_premium')::boolean is not false then
    raise exception 'Revoked license must not grant Premium';
  end if;

  -- A replacement verified license can be claimed after revocation; history remains.
  v_result := public.claim_factori_license(v_other_key,v_business);
  if not coalesce((v_result->>'ok')::boolean,false) then
    raise exception 'Replacement license claim should succeed';
  end if;
  v_result := public.get_business_entitlements(v_business);
  if v_result->>'plan_status'<>'premium' then
    raise exception 'Replacement license should restore Premium';
  end if;
  if (select count(*) from private.factori_license_entitlements
      where business_id=v_business and status='superseded')<>1 then
    raise exception 'Revoked entitlement history must be preserved as superseded';
  end if;

  -- Invalid/unverified keys cannot be claimed.
  insert into public.factori_license_keys(id,key_hash,status)
  values ('30000000-0000-4000-8000-000000000003',
    encode(extensions.digest(convert_to('UNVERIFIED-TEST-KEY','UTF8'),'sha256'),'hex'),'unused');
  begin
    perform public.claim_factori_license('UNVERIFIED-TEST-KEY',v_business);
    raise exception 'Unverified license must not be claimable';
  exception when insufficient_privilege then null;
  end;
end;
$test$;

rollback;
