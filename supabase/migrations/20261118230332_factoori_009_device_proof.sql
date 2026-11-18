-- 009: Device proof-of-possession for sync registration and access.
-- DEVELOPMENT DRAFT ONLY. Edge Function verifies P-256 signatures using WebCrypto.
begin;

alter table public.sync_devices
  add column if not exists device_key_thumbprint text,
  add column if not exists verified_at timestamptz,
  add column if not exists proof_version integer not null default 0 check(proof_version>=0);

create unique index if not exists sync_devices_active_key_uidx
 on public.sync_devices(business_id,user_id,device_key_thumbprint)
 where status='active' and device_key_thumbprint is not null;

create table if not exists public.sync_device_challenges (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null,
 device_id uuid not null,
 user_id uuid not null references auth.users(id) on delete cascade,
 challenge_hash text not null check(challenge_hash ~ '^[0-9a-f]{64}$'),
 expires_at timestamptz not null,
 consumed_at timestamptz,
 created_at timestamptz not null default now(),
 foreign key(business_id,device_id) references public.sync_devices(business_id,id) on delete cascade
);
create index if not exists sync_device_challenges_expiry_idx
 on public.sync_device_challenges(expires_at) where consumed_at is null;
alter table public.sync_device_challenges enable row level security;
revoke all on public.sync_device_challenges from public,anon,authenticated;

create or replace function public.register_sync_device_secure(
 p_business_id uuid,
 p_device_name text,
 p_platform text,
 p_device_public_key jsonb
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare
 v_user_id uuid:=auth.uid();
 v_device_id uuid;
 v_permission_version bigint;
 v_x text;
 v_y text;
 v_thumbprint text;
begin
 if v_user_id is null or not private.is_business_member(p_business_id) then
  raise exception using errcode='42501',message='Business access denied';
 end if;
 if p_platform not in ('android','web','ios','other') then
  raise exception using errcode='22023',message='Invalid device platform';
 end if;
 if jsonb_typeof(p_device_public_key)<>'object'
   or p_device_public_key->>'kty'<>'EC' or p_device_public_key->>'crv'<>'P-256'
   or p_device_public_key ? 'd' then
  raise exception using errcode='22023',message='A public-only P-256 JWK is required';
 end if;
 v_x:=p_device_public_key->>'x';
 v_y:=p_device_public_key->>'y';
 if v_x is null or v_y is null or v_x !~ '^[A-Za-z0-9_-]{43}$' or v_y !~ '^[A-Za-z0-9_-]{43}$' then
  raise exception using errcode='22023',message='Invalid P-256 public key coordinates';
 end if;
 v_thumbprint:=encode(digest(convert_to(
   '{"crv":"P-256","kty":"EC","x":"' || v_x || '","y":"' || v_y || '"}','UTF8'),'sha256'),'hex');
 select permission_version into v_permission_version from public.business_members
 where business_id=p_business_id and user_id=v_user_id and status='active';
 if not found then raise exception using errcode='42501',message='Active membership required'; end if;
 insert into public.sync_devices(
   business_id,user_id,permission_version,device_name,platform,device_public_key,
   device_key_thumbprint,verified_at,proof_version,status,last_seen_at
 ) values (
   p_business_id,v_user_id,v_permission_version,left(coalesce(p_device_name,'Factoori device'),120),
   p_platform,p_device_public_key,v_thumbprint,null,1,'active',now()
 ) on conflict(business_id,user_id,device_key_thumbprint)
   where status='active' and device_key_thumbprint is not null
   do update set device_name=excluded.device_name,platform=excluded.platform,
     permission_version=excluded.permission_version,proof_version=1,last_seen_at=now()
 returning id into v_device_id;
 insert into public.sync_cursors(business_id,device_id,last_revision,last_synced_at)
 values(p_business_id,v_device_id,0,null)
 on conflict(business_id,device_id) do nothing;
 return v_device_id;
end;
$$;

create or replace function public.create_sync_device_challenge(
 p_business_id uuid,
 p_device_id uuid
)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
 v_user_id uuid:=auth.uid();
 v_nonce text:=encode(gen_random_bytes(32),'hex');
 v_challenge_id uuid;
 v_recent_count integer;
 v_expires timestamptz:=now()+interval '3 minutes';
begin
 if v_user_id is null then raise exception using errcode='28000',message='Authentication required'; end if;
 perform 1 from public.sync_devices d join public.business_members m
   on m.business_id=d.business_id and m.user_id=d.user_id
   where d.business_id=p_business_id and d.id=p_device_id and d.user_id=v_user_id
     and d.status='active' and m.status='active' for update of d;
 if not found then
  raise exception using errcode='42501',message='Active device and membership required';
 end if;
 select count(*) into v_recent_count from public.sync_device_challenges
 where business_id=p_business_id and device_id=p_device_id and created_at>now()-interval '10 minutes';
 if v_recent_count>=10 then
  raise exception using errcode='54000',message='Too many device proof challenges; retry later';
 end if;
 insert into public.sync_device_challenges(business_id,device_id,user_id,challenge_hash,expires_at)
 values(p_business_id,p_device_id,v_user_id,
   encode(digest(convert_to(v_nonce,'UTF8'),'sha256'),'hex'),v_expires)
 returning id into v_challenge_id;
 return jsonb_build_object('challenge_id',v_challenge_id,'nonce',v_nonce,
   'business_id',p_business_id,'device_id',p_device_id,'user_id',v_user_id,'expires_at',v_expires);
end;
$$;

-- Called only by the proof-verification Edge Function using service_role.
-- The challenge is consumed atomically, so concurrent/replayed proofs cannot verify twice.
create or replace function public.finalize_sync_device_proof(
 p_challenge_id uuid,
 p_business_id uuid,
 p_device_id uuid,
 p_user_id uuid,
 p_key_thumbprint text
)
returns boolean
language plpgsql security definer set search_path=''
as $$
declare v_challenge public.sync_device_challenges%rowtype;
begin
 select * into v_challenge from public.sync_device_challenges
 where id=p_challenge_id and business_id=p_business_id and device_id=p_device_id
   and user_id=p_user_id for update;
 if not found or v_challenge.consumed_at is not null or v_challenge.expires_at<=now() then
  raise exception using errcode='42501',message='Challenge is invalid, expired or already consumed';
 end if;
 if not exists(select 1 from public.sync_devices d join public.business_members m
   on m.business_id=d.business_id and m.user_id=d.user_id
   where d.business_id=p_business_id and d.id=p_device_id and d.user_id=p_user_id
     and d.status='active' and d.device_key_thumbprint=p_key_thumbprint and m.status='active') then
  raise exception using errcode='42501',message='Device key or membership is no longer valid';
 end if;
 update public.sync_device_challenges set consumed_at=now()
 where id=p_challenge_id and consumed_at is null;
 if not found then raise exception using errcode='42501',message='Challenge replay detected'; end if;
 update public.sync_devices set verified_at=now(),last_seen_at=now()
 where business_id=p_business_id and id=p_device_id and user_id=p_user_id and status='active';
 if not found then raise exception using errcode='42501',message='Device is no longer active'; end if;
 return true;
end;
$$;

create or replace function public.revoke_sync_device(p_business_id uuid,p_device_id uuid)
returns boolean
language plpgsql security definer set search_path=''
as $$
declare v_user_id uuid:=auth.uid();
begin
 if v_user_id is null then raise exception using errcode='28000',message='Authentication required'; end if;
 update public.sync_devices set status='revoked',revoked_at=now(),verified_at=null
 where business_id=p_business_id and id=p_device_id and user_id=v_user_id and status='active';
 if found then return true; end if;
 if private.has_business_permission(p_business_id,'members.manage') then
  update public.sync_devices set status='revoked',revoked_at=now(),verified_at=null
  where business_id=p_business_id and id=p_device_id and status='active';
  return found;
 end if;
 raise exception using errcode='42501',message='Device revocation is not permitted';
end;
$$;

-- Keep the legacy registration RPC harmless: old clients may create an unverified
-- row, but the public push/pull wrappers below reject it until proof is complete.
create or replace function public.sync_push(p_business_id uuid,p_device_id uuid,p_operations jsonb)
returns jsonb language plpgsql security definer set search_path=''
as $$
begin
 if not exists(select 1 from public.sync_devices d
   where d.business_id=p_business_id and d.id=p_device_id and d.user_id=auth.uid()
     and d.status='active' and d.verified_at is not null and d.proof_version=1) then
  raise exception using errcode='42501',message='Verified sync device proof required';
 end if;
 return private.sync_push(p_business_id,p_device_id,p_operations);
end;
$$;

create or replace function public.sync_pull(p_business_id uuid,p_device_id uuid,p_since_revision bigint default 0,p_limit integer default 200)
returns jsonb language plpgsql security definer set search_path=''
as $$
begin
 if not exists(select 1 from public.sync_devices d
   where d.business_id=p_business_id and d.id=p_device_id and d.user_id=auth.uid()
     and d.status='active' and d.verified_at is not null and d.proof_version=1) then
  raise exception using errcode='42501',message='Verified sync device proof required';
 end if;
 return private.sync_pull(p_business_id,p_device_id,p_since_revision,p_limit);
end;
$$;

revoke all on function public.register_sync_device(uuid,text,text,jsonb) from public,anon,authenticated;
revoke all on function private.register_sync_device(uuid,text,text,jsonb) from public,anon,authenticated;
revoke all on function private.sync_push(uuid,uuid,jsonb) from public,anon,authenticated;
revoke all on function private.sync_pull(uuid,uuid,bigint,integer) from public,anon,authenticated;
revoke all on function public.register_sync_device_secure(uuid,text,text,jsonb) from public,anon;
revoke all on function public.create_sync_device_challenge(uuid,uuid) from public,anon;
revoke all on function public.finalize_sync_device_proof(uuid,uuid,uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.revoke_sync_device(uuid,uuid) from public,anon;
revoke all on function public.sync_push(uuid,uuid,jsonb) from public,anon;
revoke all on function public.sync_pull(uuid,uuid,bigint,integer) from public,anon;
grant execute on function public.register_sync_device_secure(uuid,text,text,jsonb) to authenticated;
grant execute on function public.create_sync_device_challenge(uuid,uuid) to authenticated;
grant execute on function public.finalize_sync_device_proof(uuid,uuid,uuid,uuid,text) to service_role;
grant execute on function public.revoke_sync_device(uuid,uuid) to authenticated;
grant execute on function public.sync_push(uuid,uuid,jsonb) to authenticated;
grant execute on function public.sync_pull(uuid,uuid,bigint,integer) to authenticated;

commit;
