-- 049: Legacy string-value collections use value:<text> identities safely.
begin;
do $$
declare v_user uuid:='a0490000-0000-4000-8000-000000000001';v_business uuid;v_service uuid;v_payload jsonb;
begin
 insert into auth.users(id,email,raw_user_meta_data) values(v_user,'factoori-service-identity-ci@example.invalid','{"display_name":"Service Identity CI"}'::jsonb) on conflict(id) do nothing;
 perform set_config('request.jwt.claim.sub',v_user::text,true);
 v_business:=public.create_business('Service Identity CI');
 v_service:=public.web_create_service(v_business,'Identity Service 049','Test',49000);
 select payload_public into v_payload from private.business_state_records where business_id=v_business and collection='services' and legacy_id='value:Identity Service 049';
 if v_payload->>'value'<>'Identity Service 049' then raise exception 'String-value legacy service identity is invalid'; end if;
end $$;
rollback;
