-- 055: Legacy purchase lines import as normalized purchase drafts without double-publishing.
begin;
do $$
declare v_user uuid:='a0550000-0000-4000-8000-000000000001';v_business uuid;v_supplier uuid;v_product uuid;v_warehouse uuid;v_result jsonb;v_document uuid;v_count integer;
begin
 insert into auth.users(id,email,raw_user_meta_data) values(v_user,'factoori-purchase-import-ci@example.invalid','{"display_name":"Purchase Import CI"}'::jsonb) on conflict(id) do nothing;
 perform set_config('request.jwt.claim.sub',v_user::text,true);
 v_business:=public.create_business('Purchase Import CI');
 v_supplier:=public.web_create_contact(v_business,'supplier','Imported Supplier 055',null,null,null,null);
 v_product:=public.web_create_product(v_business,'Imported Product 055','IMP055','عدد',5500,true,0,null);
 insert into public.warehouses(business_id,name,is_default,is_active) values(v_business,'Import Warehouse 055',true,true) returning id into v_warehouse;
 insert into private.legacy_normalized_record_map(business_id,legacy_collection,legacy_id,target_table,normalized_id,source_fingerprint,import_status,import_generation,created_by)
 values(v_business,'warehouses','legacy-warehouse-055','warehouses',v_warehouse,repeat('a',64),'mapped',gen_random_uuid(),v_user);
 insert into private.business_state_records(business_id,collection,legacy_id,payload_public,payload_private,updated_by)
 values(v_business,'purchases','legacy-purchase-055',
  jsonb_build_object('id','legacy-purchase-055','dt',current_date::text,'supplierId',(select legacy_id from public.contacts where id=v_supplier),'pid',(select legacy_id from public.products where id=v_product),'warehouseId','legacy-warehouse-055','qty',2,'paid',0,'accountId','','note','Imported purchase'),
  jsonb_build_object('unitCost',2750),v_user);
 v_result:=public.import_legacy_purchase_drafts(v_business,'a0550000-0000-4000-8000-000000000055');
 if (v_result->>'imported')::integer<>1 then raise exception 'Legacy purchase import failed: %',v_result; end if;
 select normalized_id into v_document from private.legacy_normalized_record_map where business_id=v_business and legacy_collection='purchases' and legacy_id='legacy-purchase-055';
 if not exists(select 1 from public.documents d join public.document_items i on i.business_id=d.business_id and i.document_id=d.id where d.business_id=v_business and d.id=v_document and d.document_type='purchase' and d.status='draft' and i.unit_price=2750 and i.quantity=2) then
  raise exception 'Legacy purchase did not become a normalized draft with the expected cost and quantity';
 end if;
 select count(*) into v_count from private.business_state_records where business_id=v_business and collection='purchases';
 if v_count<>1 then raise exception 'Imported purchase draft was re-published as a duplicate mobile purchase';
 end if;
 v_result:=public.import_legacy_purchase_drafts(v_business,'a0550000-0000-4000-8000-000000000056');
 if (v_result->>'unchanged')::integer<>1 then raise exception 'Purchase import is not idempotent: %',v_result; end if;
end $$;
rollback;
