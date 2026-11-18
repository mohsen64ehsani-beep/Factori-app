-- 013: Account/business-bound perpetual license entitlements.
-- DEVELOPMENT DRAFT ONLY. Depends on 001-012 and the existing production license-key schema.
-- Never apply to production without explicit approval and a rehearsed legacy migration.

begin;

create table if not exists private.factori_license_entitlements (
  id uuid primary key default gen_random_uuid(),
  license_id uuid not null references public.factori_license_keys(id) on delete restrict,
  business_id uuid not null references public.businesses(id) on delete restrict,
  purchaser_user_id uuid not null references auth.users(id) on delete restrict,
  claimed_at timestamptz not null default now(),
  status text not null default 'active' check (status in ('active','superseded')),
  claim_source text not null default 'purchase_key'
    check (claim_source in ('purchase_key','support_migration')),
  created_at timestamptz not null default now(),
  constraint factori_license_entitlements_license_uq unique (license_id)
);
create unique index if not exists factori_license_entitlements_one_active_business_uq
  on private.factori_license_entitlements(business_id) where status='active';

create table if not exists private.factori_license_entitlement_events (
  id bigint generated always as identity primary key,
  entitlement_id uuid references private.factori_license_entitlements(id) on delete restrict,
  license_id uuid not null references public.factori_license_keys(id) on delete restrict,
  business_id uuid not null references public.businesses(id) on delete restrict,
  actor_user_id uuid references auth.users(id) on delete set null,
  event_code text not null check (event_code in ('claimed','claim_replayed')),
  created_at timestamptz not null default now()
);

create index if not exists factori_license_entitlements_purchaser_idx
  on private.factori_license_entitlements(purchaser_user_id,business_id);

revoke all on private.factori_license_entitlements,
  private.factori_license_entitlement_events from public,anon,authenticated,service_role;

create or replace function public.claim_factori_license(
  p_license_key text,
  p_business_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_hash text;
  v_license public.factori_license_keys%rowtype;
  v_existing private.factori_license_entitlements%rowtype;
  v_entitlement_id uuid;
begin
  if v_user is null then
    raise exception using errcode='28000',message='Authentication required';
  end if;
  if p_business_id is null or p_license_key is null
     or length(btrim(p_license_key)) < 8 or length(btrim(p_license_key)) > 256 then
    raise exception using errcode='22023',message='Invalid license claim input';
  end if;
  if not exists (
    select 1 from public.businesses b
    join public.business_members m on m.business_id=b.id
    where b.id=p_business_id and b.owner_user_id=v_user
      and m.user_id=v_user and m.role_code='owner' and m.status='active'
      and b.status='active'
  ) then
    raise exception using errcode='42501',message='Only the active business owner can claim a license';
  end if;

  v_hash := encode(extensions.digest(convert_to(btrim(p_license_key),'UTF8'),'sha256'),'hex');

  select * into v_license
  from public.factori_license_keys
  where key_hash=v_hash
  for update;

  if not found then
    raise exception using errcode='22023',message='License key is invalid';
  end if;
  if v_license.status='revoked' then
    raise exception using errcode='22023',message='License is revoked';
  end if;
  if v_license.status not in ('unused','active') then
    raise exception using errcode='22023',message='License is not claimable';
  end if;
  -- New unactivated keys must have a verified payment. Existing activated keys
  -- can be claimed by proving possession of their original key.
  if v_license.payment_verified_at is null and not (
    v_license.status='active' and exists (
      select 1 from public.factori_license_activations a where a.license_id=v_license.id
    )
  ) then
    raise exception using errcode='42501',message='License purchase is not verified';
  end if;

  select * into v_existing
  from private.factori_license_entitlements
  where license_id=v_license.id
  for update;

  if found then
    if v_existing.business_id=p_business_id and v_existing.purchaser_user_id=v_user then
      insert into private.factori_license_entitlement_events
        (entitlement_id,license_id,business_id,actor_user_id,event_code)
      values (v_existing.id,v_license.id,p_business_id,v_user,'claim_replayed');
      return jsonb_build_object('ok',true,'already_claimed',true,'business_id',p_business_id);
    end if;
    raise exception using errcode='23505',message='License is already claimed by another account or business';
  end if;

  -- Keep revoked entitlements in the audit history, but allow a replacement
  -- purchase to become the business's single active perpetual entitlement.
  update private.factori_license_entitlements e
  set status='superseded'
  from public.factori_license_keys k
  where e.license_id=k.id and e.business_id=p_business_id
    and e.status='active' and k.status='revoked';

  if exists (
    select 1 from private.factori_license_entitlements e
    join public.factori_license_keys k on k.id=e.license_id
    where e.business_id=p_business_id and e.status='active'
      and k.status in ('unused','active')
  ) then
    raise exception using errcode='23505',message='Business already has a perpetual license';
  end if;

  insert into private.factori_license_entitlements
    (license_id,business_id,purchaser_user_id,claim_source)
  values (v_license.id,p_business_id,v_user,'purchase_key')
  returning id into v_entitlement_id;

  insert into private.factori_license_entitlement_events
    (entitlement_id,license_id,business_id,actor_user_id,event_code)
  values (v_entitlement_id,v_license.id,p_business_id,v_user,'claimed');

  return jsonb_build_object('ok',true,'already_claimed',false,'business_id',p_business_id);
end;
$$;

revoke all on function public.claim_factori_license(text,uuid) from public,anon;
grant execute on function public.claim_factori_license(text,uuid) to authenticated;

create or replace function public.get_business_entitlements(p_business_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_owner uuid;
  v_entitlement record;
begin
  if auth.uid() is null or not private.is_business_member(p_business_id) then
    raise exception using errcode='42501',message='Business access denied';
  end if;

  select owner_user_id into v_owner
  from public.businesses
  where id=p_business_id and status='active';

  if v_owner is null then
    raise exception using errcode='P0002',message='Business not found';
  end if;

  select e.id,e.license_id,e.claimed_at,k.status
    into v_entitlement
  from private.factori_license_entitlements e
  join public.factori_license_keys k on k.id=e.license_id
  where e.business_id=p_business_id
    and e.purchaser_user_id=v_owner
    and e.status='active'
    and k.status in ('unused','active')
  limit 1;

  if v_entitlement.id is null then
    return jsonb_build_object(
      'business_id',p_business_id,
      'plan_status','free',
      'is_premium',false,
      'license_type',null
    );
  end if;

  return jsonb_build_object(
    'business_id',p_business_id,
    'plan_status','premium',
    'is_premium',true,
    'license_type','perpetual',
    'license_id',v_entitlement.license_id,
    'claimed_at',v_entitlement.claimed_at
  );
end;
$$;

revoke all on function public.get_business_entitlements(uuid) from public,anon;
grant execute on function public.get_business_entitlements(uuid) to authenticated;


create or replace function private.business_has_premium_entitlement(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from private.factori_license_entitlements e
    join public.factori_license_keys k on k.id=e.license_id
    join public.businesses b on b.id=e.business_id
    where e.business_id=p_business_id
      and e.status='active'
      and e.purchaser_user_id=b.owner_user_id
      and b.status='active'
      and k.status in ('unused','active')
  );
$$;

revoke all on function private.business_has_premium_entitlement(uuid) from public,anon,authenticated;

-- Premium entitlement is checked inside the same server-side quota functions
-- used by sync/document RPCs. Client-side license flags are never authoritative.
create or replace function private.assert_feature_limit(p_business_id uuid,p_feature_code text,p_requested integer)
returns void language plpgsql security definer set search_path=''
as $$
declare v_limit integer; v_period text; v_current bigint:=0; v_collection text;
begin
 if auth.uid() is null or not private.is_business_member(p_business_id) then
  raise exception using errcode='42501',message='Business access denied';
 end if;
 if private.business_has_premium_entitlement(p_business_id) then return; end if;
 if p_requested is null or p_requested<0 then
  raise exception using errcode='22023',message='Invalid requested feature quantity';
 end if;
 select limit_value,period_type into v_limit,v_period
 from public.business_feature_limits
 where business_id=p_business_id and feature_code=p_feature_code and enabled
 for update;
 if not found then raise exception using errcode='55000',message='Feature entitlement is not configured'; end if;
 if v_limit is null then return; end if;
 if v_period='per_record' then
  if p_requested>v_limit then raise exception using errcode='54000',message='Per-record feature limit exceeded'; end if;
  return;
 end if;
 v_collection:=case p_feature_code
  when 'customers.total_limit' then 'cust'
  when 'products.total_limit' then 'prod'
  when 'services.total_limit' then 'services'
  when 'warehouses.total_limit' then 'warehouses'
  else null end;
 if v_collection is not null then
  execute 'select count(*) from private.business_state_records where business_id=$1 and collection=$2 and deleted_at is null'
   into v_current using p_business_id,v_collection;
  if v_current+p_requested>v_limit then
   raise exception using errcode='54000',message='Business feature limit exceeded';
  end if;
  return;
 end if;
 if p_requested>v_limit then raise exception using errcode='54000',message='Feature limit exceeded'; end if;
end;
$$;

create or replace function private.consume_feature_quota(p_business_id uuid,p_feature_code text,p_usage_date date,p_operation_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare v_limit integer; v_period text; v_count bigint; v_inserted uuid;
begin
 if auth.uid() is null or not private.is_business_member(p_business_id) then
  raise exception using errcode='42501',message='Business access denied';
 end if;
 if private.business_has_premium_entitlement(p_business_id) then return; end if;
 if p_usage_date is null or p_operation_id is null then
  raise exception using errcode='22023',message='Quota date and operation ID are required';
 end if;
 select limit_value,period_type into v_limit,v_period
 from public.business_feature_limits
 where business_id=p_business_id and feature_code=p_feature_code and enabled
 for update;
 if not found then raise exception using errcode='55000',message='Feature entitlement is not configured'; end if;
 if v_period<>'daily' then raise exception using errcode='22023',message='Feature does not use a daily quota'; end if;
 if v_limit is null then return; end if;
 insert into public.business_feature_usage(business_id,feature_code,usage_date,operation_id)
 values(p_business_id,p_feature_code,p_usage_date,p_operation_id)
 on conflict(business_id,feature_code,usage_date,operation_id) do nothing
 returning id into v_inserted;
 if v_inserted is null then return; end if;
 select count(*) into v_count from public.business_feature_usage
 where business_id=p_business_id and feature_code=p_feature_code and usage_date=p_usage_date;
 if v_count>v_limit then raise exception using errcode='54000',message='Daily feature quota exceeded'; end if;
end;
$$;

revoke all on function private.assert_feature_limit(uuid,text,integer) from public,anon,authenticated;
revoke all on function private.consume_feature_quota(uuid,text,date,uuid) from public,anon,authenticated;

commit;
