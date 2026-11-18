-- 050: Draft creation publishes only after document line items exist.
begin;
do $$
declare v_user uuid:='a0500000-0000-4000-8000-000000000001';v_business uuid;v_contact uuid;v_service uuid;v_product uuid;v_document uuid;v_payload jsonb;
begin
 insert into auth.users(id,email,raw_user_meta_data) values(v_user,'factoori-document-items-bridge-ci@example.invalid','{"display_name":"Document Items Bridge CI"}'::jsonb) on conflict(id) do nothing;
 perform set_config('request.jwt.claim.sub',v_user::text,true);
 v_business:=public.create_business('Document Items Bridge CI');
 v_contact:=public.web_create_contact(v_business,'customer','Document Customer 050',null,null,null,null);
 v_service:=public.web_create_service(v_business,'Service 050','Test service',50000);
 v_document:=public.create_document_draft(v_business,'service_sale',v_contact,null,null,current_date,null,'service bridge',0,0,
  jsonb_build_array(jsonb_build_object('item_type','service','service_id',v_service,'description','Service 050','quantity',1,'unit_name','خدمت','unit_price',50000,'discount_amount',0,'tax_rate',0)),
  'service-items-050');
 select payload_public into v_payload from private.business_state_records where business_id=v_business and collection='serviceInv' and legacy_id=v_document::text;
 if v_payload is null or jsonb_array_length(coalesce(v_payload->'items','[]'::jsonb))<>1 then raise exception 'Service draft lines were not published to mobile sync'; end if;
 v_product:=public.web_create_product(v_business,'Product 050','P050','عدد',5000,true,0,null);
 v_document:=public.create_document_draft(v_business,'goods_sale',v_contact,null,null,current_date,null,'goods bridge',0,0,
  jsonb_build_array(jsonb_build_object('item_type','goods','product_id',v_product,'description','Product 050','quantity',1,'unit_name','عدد','unit_price',5000,'discount_amount',0,'tax_rate',0)),
  'goods-items-050');
 select payload_public into v_payload from private.business_state_records where business_id=v_business and collection='inv' and legacy_id=v_document::text;
 if v_payload is null or jsonb_array_length(coalesce(v_payload->'items','[]'::jsonb))<>1 then raise exception 'Goods draft lines were not published to mobile sync'; end if;
end $$;
rollback;
