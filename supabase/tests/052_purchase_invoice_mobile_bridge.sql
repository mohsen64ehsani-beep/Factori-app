-- 052: Web purchase drafts are mirrored line-by-line to Android purchases with protected unit cost.
begin;
do $$
declare v_user uuid:='a0520000-0000-4000-8000-000000000001';v_business uuid;v_contact uuid;v_product uuid;v_warehouse uuid;v_document uuid;v_record_id text;v_payload jsonb;v_private jsonb;
begin
 insert into auth.users(id,email,raw_user_meta_data) values(v_user,'factoori-purchase-bridge-ci@example.invalid','{"display_name":"Purchase Bridge CI"}'::jsonb) on conflict(id) do nothing;
 perform set_config('request.jwt.claim.sub',v_user::text,true);
 v_business:=public.create_business('Purchase Bridge CI');
 v_contact:=public.web_create_contact(v_business,'supplier','Purchase Supplier 052',null,null,null,null);
 v_product:=public.web_create_product(v_business,'Purchase Product 052','PUR052','عدد',5200,true,0,null);
 insert into public.warehouses(business_id,name,is_default,is_active) values(v_business,'Purchase Warehouse 052',true,true) returning id into v_warehouse;
 v_document:=public.create_document_draft(v_business,'purchase',v_contact,v_warehouse,null,current_date,null,'Purchase bridge test',0,0,
  jsonb_build_array(jsonb_build_object('item_type','goods','product_id',v_product,'description','Purchase Product 052','quantity',2,'unit_name','عدد','unit_price',3000,'discount_amount',0,'tax_rate',0)),
  'purchase-bridge-052');
 v_record_id:=v_document::text||':'||(select id::text from public.document_items where business_id=v_business and document_id=v_document limit 1);
 select payload_public,payload_private into v_payload,v_private from private.business_state_records where business_id=v_business and collection='purchases' and legacy_id=v_record_id;
 if v_payload is null or v_payload->>'pid' is null or (v_payload->>'qty')::numeric<>2 then raise exception 'Purchase line was not mirrored to Android'; end if;
 if v_payload ? 'unitCost' then raise exception 'Purchase cost leaked into public legacy payload'; end if;
 if v_private->>'unitCost' is distinct from '3000' then raise exception 'Purchase unit cost was not partitioned into private payload'; end if;
end $$;
rollback;
