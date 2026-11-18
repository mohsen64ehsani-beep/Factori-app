-- 048: Web service catalog and service-sale drafts are shared with the Android service collections.
begin;
do $$
declare v_user uuid:='a0480000-0000-4000-8000-000000000001';v_business uuid;v_contact uuid;v_service uuid;v_document uuid;v_payload jsonb;
begin
 insert into auth.users(id,email,raw_user_meta_data) values(v_user,'factoori-service-bridge-ci@example.invalid','{"display_name":"Service Bridge CI"}'::jsonb) on conflict(id) do nothing;
 perform set_config('request.jwt.claim.sub',v_user::text,true);
 v_business:=public.create_business('Service Bridge CI');
 v_contact:=public.web_create_contact(v_business,'customer','Service Customer 048',null,null,null,null);
 v_service:=public.web_create_service(v_business,'Web Service 048','Service bridge test',48000);
 select payload_public into v_payload from private.business_state_records where business_id=v_business and collection='services' and legacy_id='value:Web Service 048';
 if v_payload is null or v_payload->>'value'<>'Web Service 048' then raise exception 'Web service was not published to Android services collection'; end if;
 v_document:=public.create_document_draft(v_business,'service_sale',v_contact,null,null,current_date,null,'service invoice bridge',0,0,
  jsonb_build_array(jsonb_build_object('item_type','service','service_id',v_service,'description','Web Service 048','quantity',1,'unit_name','خدمت','unit_price',48000,'discount_amount',0,'tax_rate',0)),
  'service-bridge-048');
 select payload_public into v_payload from private.business_state_records where business_id=v_business and collection='serviceInv' and legacy_id=v_document::text;
 if v_payload is null or jsonb_array_length(coalesce(v_payload->'items','[]'::jsonb))<>1 then raise exception 'Service sale draft was not mirrored to Android service invoice collection'; end if;
end $$;
rollback;
