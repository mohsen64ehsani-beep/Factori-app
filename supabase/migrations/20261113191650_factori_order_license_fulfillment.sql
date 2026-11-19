create table if not exists public.factori_license_keys(
 id uuid primary key default gen_random_uuid(),
 key_hash text not null,
 status text not null default 'unused' check(status in ('unused','active','revoked')),
 created_at timestamptz not null default now(),
 activated_at timestamptz,
 revoked_at timestamptz,
 order_id text,
 encrypted_key text,
 payment_reference text,
 payment_gateway text,
 amount_paid_toman bigint,
 payment_verified_at timestamptz
);
alter table public.factori_license_keys
 add column if not exists order_id text,
 add column if not exists encrypted_key text,
 add column if not exists payment_reference text,
 add column if not exists payment_gateway text,
 add column if not exists amount_paid_toman bigint,
 add column if not exists payment_verified_at timestamptz;
create unique index if not exists factori_license_keys_key_hash_key on public.factori_license_keys(key_hash);
create unique index if not exists factori_license_keys_order_id_uidx on public.factori_license_keys(order_id) where order_id is not null;
alter table public.factori_license_keys enable row level security;
revoke all on public.factori_license_keys from public,anon,authenticated;
grant select,insert,update,delete on public.factori_license_keys to service_role;

create or replace function public.factori_issue_order_license(
 p_order_id text,p_key_hash text,p_encrypted_key text,p_payment_reference text,
 p_payment_gateway text,p_amount_paid_toman bigint
)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare v_license public.factori_license_keys%rowtype;v_created boolean:=false;
begin
 if p_order_id is null or length(trim(p_order_id))=0 or p_key_hash is null or length(p_key_hash)<>64
  or p_encrypted_key is null or p_payment_reference is null or p_payment_gateway is null
  or p_amount_paid_toman is null or p_amount_paid_toman<=0 then
  raise exception 'invalid_license_issue_input';
 end if;
 insert into public.factori_license_keys
  (key_hash,status,order_id,encrypted_key,payment_reference,payment_gateway,amount_paid_toman,payment_verified_at)
 values(p_key_hash,'unused',p_order_id,p_encrypted_key,p_payment_reference,p_payment_gateway,p_amount_paid_toman,now())
 on conflict(order_id) where order_id is not null do nothing returning * into v_license;
 if found then v_created:=true;
 else
  select * into v_license from public.factori_license_keys where order_id=p_order_id for update;
  if not found then raise exception 'license_issue_conflict';end if;
 end if;
 return jsonb_build_object('ok',true,'created',v_created,'license_id',v_license.id,'status',v_license.status,'encrypted_key',v_license.encrypted_key);
end;$function$;
revoke all on function public.factori_issue_order_license(text,text,text,text,text,bigint) from public,anon,authenticated;
grant execute on function public.factori_issue_order_license(text,text,text,text,text,bigint) to service_role;
