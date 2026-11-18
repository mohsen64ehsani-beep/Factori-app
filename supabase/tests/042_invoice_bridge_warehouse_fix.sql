-- 042: Invoice bridge remains safe when a document uses a non-numeric external number.
begin;
do $$
declare
 v_user uuid:='a0420000-0000-4000-8000-000000000001'; v_business uuid; v_contact uuid; v_product uuid; v_document uuid; v_number text;
begin
 insert into auth.users(id,email,raw_user_meta_data) values(v_user,'factoori-invoice-number-ci@example.invalid','{"display_name":"Invoice Number CI"}'::jsonb) on conflict(id) do nothing;
 perform set_config('request.jwt.claim.sub',v_user::text,true);
 v_business:=public.create_business('Invoice Number CI');
 v_contact:=public.web_create_contact(v_business,'customer','Invoice Customer 042',null,null,null,null);
 v_product:=public.web_create_product(v_business,'Invoice Product 042','INV042','عدد',4200,true,0,null);
 v_document:=public.create_document_draft(v_business,'goods_sale',v_contact,null,null,current_date,null,'number bridge test',0,0,
  jsonb_build_array(jsonb_build_object('item_type','goods','product_id',v_product,'description','Invoice Product 042','quantity',1,'unit_name','عدد','unit_price',4200,'discount_amount',0,'tax_rate',0)),
  'invoice-number-ci-042');
 update public.documents set document_number='EXT-042' where id=v_document and business_id=v_business;
 select payload_public->>'no' into v_number from private.business_state_records where business_id=v_business and collection='inv' and legacy_id=v_document::text;
 if v_number<>'0' then raise exception 'Non-numeric external invoice number was not safely represented'; end if;
end $$;
rollback;
