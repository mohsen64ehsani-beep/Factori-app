-- 051: Service-sale drafts receive a mobile-compatible invoice number.
begin;
do $$
declare v_user uuid:='a0510000-0000-4000-8000-000000000001';v_business uuid;v_contact uuid;v_service uuid;v_document uuid;v_number text;
begin
 insert into auth.users(id,email,raw_user_meta_data) values(v_user,'factoori-service-number-ci@example.invalid','{"display_name":"Service Number CI"}'::jsonb) on conflict(id) do nothing;
 perform set_config('request.jwt.claim.sub',v_user::text,true);
 v_business:=public.create_business('Service Number CI');
 v_contact:=public.web_create_contact(v_business,'customer','Service Number Customer 051',null,null,null,null);
 v_service:=public.web_create_service(v_business,'Service Number 051','Test',51000);
 v_document:=public.create_document_draft(v_business,'service_sale',v_contact,null,null,current_date,null,'service number',0,0,
  jsonb_build_array(jsonb_build_object('item_type','service','service_id',v_service,'description','Service Number 051','quantity',1,'unit_name','خدمت','unit_price',51000,'discount_amount',0,'tax_rate',0)),
  'service-number-051');
 select document_number into v_number from public.documents where business_id=v_business and id=v_document;
 if coalesce(v_number,'') !~ '^[0-9]+$' then raise exception 'Service-sale draft did not receive numeric invoice number: %',v_number; end if;
end $$;
rollback;
