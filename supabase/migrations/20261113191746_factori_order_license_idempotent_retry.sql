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
 if found then
  v_created:=true;
 else
  select * into v_license from public.factori_license_keys where order_id=p_order_id for update;
  if not found then raise exception 'license_issue_conflict';end if;
  if v_license.key_hash<>p_key_hash or v_license.encrypted_key<>p_encrypted_key
    or v_license.payment_reference<>p_payment_reference
    or v_license.payment_gateway<>p_payment_gateway
    or v_license.amount_paid_toman<>p_amount_paid_toman then
   raise exception 'license_issue_conflict';
  end if;
 end if;
 return jsonb_build_object('ok',true,'created',v_created,'license_id',v_license.id,'status',v_license.status,'encrypted_key',v_license.encrypted_key);
end;$function$;
revoke all on function public.factori_issue_order_license(text,text,text,text,text,bigint) from public,anon,authenticated;
grant execute on function public.factori_issue_order_license(text,text,text,text,text,bigint) to service_role;
