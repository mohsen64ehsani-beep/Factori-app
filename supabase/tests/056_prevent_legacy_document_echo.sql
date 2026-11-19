-- 056: Documents imported from Android must not echo back into Android as new invoice records.
begin;
do $$
declare v_user uuid:='a0560000-0000-4000-8000-000000000001';v_business uuid;v_contact uuid;v_product uuid;v_warehouse uuid;v_document uuid;v_before integer;v_after integer;
begin
 insert into auth.users(id,email,raw_user_meta_data) values(v_user,'factoori-import-no-echo-ci@example.invalid','{"display_name":"Import No Echo CI"}'::jsonb) on conflict(id) do nothing;
 perform set_config('request.jwt.claim.sub',v_user::text,true);
 v_business:=public.create_business('Import No Echo CI');
 v_contact:=public.web_create_contact(v_business,'customer','No Echo Customer 056',null,null,null,null);
 v_product:=public.web_create_product(v_business,'No Echo Product 056','NE056','عدد',5600,true,0,null);
 insert into public.warehouses(business_id,name,is_default,is_active) values(v_business,'No Echo Warehouse 056',true,true) returning id into v_warehouse;
 v_document:=public.create_document_draft(v_business,'goods_sale',v_contact,v_warehouse,null,current_date,null,'Imported document',0,0,
  jsonb_build_array(jsonb_build_object('item_type','goods','product_id',v_product,'description','No Echo Product 056','quantity',1,'unit_name','عدد','unit_price',5600,'discount_amount',0,'tax_rate',0)),
  'legacy-inv:fixture-056');
 select count(*) into v_before from private.business_state_records where business_id=v_business and collection='inv';
 update public.documents set notes='Imported document revised' where business_id=v_business and id=v_document;
 select count(*) into v_after from private.business_state_records where business_id=v_business and collection='inv';
 if v_after<>v_before then raise exception 'Legacy-imported document was echoed back into Android sync'; end if;
end $$;
rollback;
