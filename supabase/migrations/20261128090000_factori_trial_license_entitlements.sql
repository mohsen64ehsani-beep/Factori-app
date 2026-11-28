-- Account-bound 24-hour trial licenses, server expiry, and in-place trial-to-permanent upgrade.
-- Keeps existing license ownership, business entitlement, and activation records intact.
begin;
create or replace function public.claim_factori_license(p_license_key text,p_business_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_user uuid:=auth.uid(); v_email text; v_hash text; v_license public.factori_license_keys%rowtype;
v_existing private.factori_license_entitlements%rowtype; v_entitlement_id uuid;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required'; end if;
 if p_business_id is null or p_license_key is null or length(btrim(p_license_key))<8 or length(btrim(p_license_key))>256 then raise exception using errcode='22023',message='Invalid license claim input'; end if;
 select lower(email) into v_email from auth.users where id=v_user;
 if v_email is null then raise exception using errcode='28000',message='Verified account email required'; end if;
 if not exists(select 1 from public.businesses b join public.business_members m on m.business_id=b.id where b.id=p_business_id and b.owner_user_id=v_user and m.user_id=v_user and m.role_code='owner' and m.status='active' and b.status='active') then raise exception using errcode='42501',message='Only the active business owner can claim a license'; end if;
 v_hash:=encode(extensions.digest(convert_to(btrim(p_license_key),'UTF8'),'sha256'),'hex');
 select * into v_license from public.factori_license_keys where key_hash=v_hash for update;
 if not found then raise exception using errcode='22023',message='License key is invalid'; end if;
 if v_license.status='revoked' then raise exception using errcode='22023',message='License is revoked'; end if;
 if v_license.status='expired' or (v_license.expires_at is not null and v_license.expires_at<=now()) then update public.factori_license_keys set status='expired' where id=v_license.id and status in ('unused','active'); raise exception using errcode='22023',message='License has expired'; end if;
 if v_license.status not in ('unused','active') then raise exception using errcode='22023',message='License is not claimable'; end if;
 if v_license.owner_email is not null and lower(v_license.owner_email)<>v_email then raise exception using errcode='42501',message='License email does not match signed-in account'; end if;
 if v_license.owner_email is null and v_license.payment_verified_at is null and not (v_license.status='active' and exists(select 1 from public.factori_license_activations a where a.license_id=v_license.id)) then raise exception using errcode='42501',message='License purchase is not verified'; end if;
 select * into v_existing from private.factori_license_entitlements where license_id=v_license.id for update;
 if found then
  if v_existing.business_id=p_business_id and v_existing.purchaser_user_id=v_user and v_existing.status='active' then
   insert into private.factori_license_entitlement_events(entitlement_id,license_id,business_id,actor_user_id,event_code) values(v_existing.id,v_license.id,p_business_id,v_user,'claim_replayed');
   return jsonb_build_object('ok',true,'already_claimed',true,'business_id',p_business_id);
  end if;
  raise exception using errcode='23505',message='License is already claimed by another account or business';
 end if;
 update private.factori_license_entitlements e set status='superseded' from public.factori_license_keys k
 where e.license_id=k.id and e.business_id=p_business_id and e.status='active'
 and (k.status in ('revoked','expired') or (k.expires_at is not null and k.expires_at<=now()));
 if exists(select 1 from private.factori_license_entitlements e join public.factori_license_keys k on k.id=e.license_id where e.business_id=p_business_id and e.status='active' and k.status in ('unused','active') and (k.expires_at is null or k.expires_at>now())) then raise exception using errcode='23505',message='Business already has an active license'; end if;
 insert into private.factori_license_entitlements(license_id,business_id,purchaser_user_id,claim_source) values(v_license.id,p_business_id,v_user,'purchase_key') returning id into v_entitlement_id;
 insert into private.factori_license_entitlement_events(entitlement_id,license_id,business_id,actor_user_id,event_code) values(v_entitlement_id,v_license.id,p_business_id,v_user,'claimed');
 return jsonb_build_object('ok',true,'already_claimed',false,'business_id',p_business_id);
end; $$;
revoke all on function public.claim_factori_license(text,uuid) from public,anon;
grant execute on function public.claim_factori_license(text,uuid) to authenticated;
create or replace function public.get_business_entitlements(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_owner uuid; v_entitlement record;
begin
 if auth.uid() is null or not private.is_business_member(p_business_id) then raise exception using errcode='42501',message='Business access denied'; end if;
 select owner_user_id into v_owner from public.businesses where id=p_business_id and status='active';
 if v_owner is null then raise exception using errcode='P0002',message='Business not found'; end if;
 select e.id,e.license_id,e.claimed_at,k.status,k.license_type,k.expires_at,k.owner_email into v_entitlement
 from private.factori_license_entitlements e join public.factori_license_keys k on k.id=e.license_id
 where e.business_id=p_business_id and e.purchaser_user_id=v_owner and e.status='active'
 and k.status in ('unused','active') and (k.expires_at is null or k.expires_at>now()) order by e.claimed_at desc limit 1;
 if v_entitlement.id is null then return jsonb_build_object('business_id',p_business_id,'plan_status','free','is_premium',false,'license_type',null,'expires_at',null); end if;
 return jsonb_build_object('business_id',p_business_id,'plan_status',case when v_entitlement.license_type='trial_24h' then 'trial' else 'premium' end,'is_premium',true,'license_type',coalesce(v_entitlement.license_type,'permanent'),'expires_at',v_entitlement.expires_at,'owner_email',v_entitlement.owner_email,'license_id',v_entitlement.license_id,'claimed_at',v_entitlement.claimed_at);
end; $$;
revoke all on function public.get_business_entitlements(uuid) from public,anon;
grant execute on function public.get_business_entitlements(uuid) to authenticated;
create or replace function private.business_has_premium_entitlement(p_business_id uuid)
returns boolean language sql stable security definer set search_path=''
as $$ select exists(select 1 from private.factori_license_entitlements e join public.factori_license_keys k on k.id=e.license_id join public.businesses b on b.id=e.business_id where e.business_id=p_business_id and e.status='active' and e.purchaser_user_id=b.owner_user_id and b.status='active' and k.status in ('unused','active') and (k.expires_at is null or k.expires_at>now())); $$;
revoke all on function private.business_has_premium_entitlement(uuid) from public,anon,authenticated;
commit;