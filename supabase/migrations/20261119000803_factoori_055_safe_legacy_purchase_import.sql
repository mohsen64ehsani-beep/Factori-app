begin;
alter table private.legacy_normalized_record_map drop constraint if exists legacy_normalized_record_map_legacy_collection_check;
alter table private.legacy_normalized_record_map add constraint legacy_normalized_record_map_legacy_collection_check
check (legacy_collection = any(array['cust','suppliers','prod','categories','warehouses','services','inv','serviceInv','fiscal','pay','supplierPayments','expenses','otherincome','purchases']));

create or replace function private.publish_document_to_legacy(p_business_id uuid,p_document_id uuid,p_actor uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_doc public.documents%rowtype;v_contact_legacy text;v_items jsonb;v_payload jsonb;v_tax_rate numeric:=0;v_cost_allowed boolean;v_invoice_number bigint:=0;v_item record;v_product_legacy text;v_warehouse_legacy text;v_purchase_id text;
begin
 select * into v_doc from public.documents where business_id=p_business_id and id=p_document_id;
 if not found or v_doc.document_type not in ('goods_sale','service_sale','purchase') then return; end if;
 if coalesce(v_doc.idempotency_key,'') like 'legacy-import-%' then return; end if;
 if not exists(select 1 from public.document_items i where i.business_id=p_business_id and i.document_id=p_document_id) then return; end if;
 select c.legacy_id into v_contact_legacy from public.contacts c where c.business_id=p_business_id and c.id=v_doc.contact_id;
 select coalesce(max(i.tax_rate_snapshot),0) into v_tax_rate from public.document_items i where i.business_id=p_business_id and i.document_id=p_document_id;
 v_cost_allowed:=private.has_business_permission(p_business_id,'catalog.cost.read');
 if coalesce(v_doc.document_number,'') ~ '^[0-9]+$' then v_invoice_number:=v_doc.document_number::bigint; end if;
 if v_doc.document_type='goods_sale' then
  select coalesce(jsonb_agg(jsonb_build_object('pid',coalesce(p.legacy_id,i.product_id::text),'n',i.description_snapshot,'q',i.quantity,'p',i.unit_price,'b',case when v_cost_allowed then coalesce(c.unit_cost_snapshot,0) else 0 end) order by i.sort_order),'[]'::jsonb)
  into v_items from public.document_items i left join public.products p on p.business_id=i.business_id and p.id=i.product_id left join public.document_item_costs c on c.business_id=i.business_id and c.document_item_id=i.id where i.business_id=p_business_id and i.document_id=p_document_id;
  v_payload:=jsonb_build_object('id',v_doc.id::text,'no',v_invoice_number,'dt',v_doc.document_date::text,'createdAt',v_doc.created_at::date::text,'cid',coalesce(v_contact_legacy,v_doc.contact_id::text),'warehouseId','','bankAccountId','','items',v_items,'ds',v_doc.discount_amount,'tx',v_tax_rate,'status',v_doc.status,'notes',coalesce(v_doc.notes,''));
  perform private.write_legacy_master_record(p_business_id,'inv',v_doc.id::text,v_payload,false,coalesce(p_actor,v_doc.created_by,auth.uid()));
 elsif v_doc.document_type='service_sale' then
  select coalesce(jsonb_agg(jsonb_build_object('desc',i.description_snapshot,'qty',i.quantity,'price',i.unit_price,'cost',case when v_cost_allowed then coalesce(c.unit_cost_snapshot,0) else 0 end) order by i.sort_order),'[]'::jsonb)
  into v_items from public.document_items i left join public.document_item_costs c on c.business_id=i.business_id and c.document_item_id=i.id where i.business_id=p_business_id and i.document_id=p_document_id;
  v_payload:=jsonb_build_object('id',v_doc.id::text,'no',v_invoice_number,'dt',v_doc.document_date::text,'createdAt',v_doc.created_at::date::text,'cid',coalesce(v_contact_legacy,v_doc.contact_id::text),'bankAccountId','','items',v_items,'discount',v_doc.discount_amount,'costMode','row','costTotal',0,'status',v_doc.status);
  perform private.write_legacy_master_record(p_business_id,'serviceInv',v_doc.id::text,v_payload,false,coalesce(p_actor,v_doc.created_by,auth.uid()));
 else
  select m.legacy_id into v_warehouse_legacy from private.legacy_normalized_record_map m where m.business_id=p_business_id and m.legacy_collection='warehouses' and m.normalized_id=v_doc.warehouse_id and m.import_status='mapped' limit 1;
  for v_item in select i.*,p.legacy_id as product_legacy_id from public.document_items i left join public.products p on p.business_id=i.business_id and p.id=i.product_id where i.business_id=p_business_id and i.document_id=p_document_id order by i.sort_order loop
   v_purchase_id:=v_doc.id::text||':'||v_item.id::text;v_product_legacy:=coalesce(v_item.product_legacy_id,v_item.product_id::text);
   v_payload:=jsonb_build_object('id',v_purchase_id,'dt',v_doc.document_date::text,'supplierId',coalesce(v_contact_legacy,v_doc.contact_id::text),'pid',v_product_legacy,'warehouseId',coalesce(v_warehouse_legacy,v_doc.warehouse_id::text,''),'qty',v_item.quantity,'unitCost',v_item.unit_price,'paid',0,'accountId','','note',coalesce(v_doc.notes,v_item.description_snapshot,''));
   perform private.write_legacy_master_record(p_business_id,'purchases',v_purchase_id,v_payload,false,coalesce(p_actor,v_doc.created_by,auth.uid()));
  end loop;
 end if;
end; $$;

create or replace function public.import_legacy_purchase_drafts(p_business_id uuid,p_import_generation uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v_user uuid:=auth.uid();v_row record;v_payload jsonb;v_legacy_id text;v_fingerprint text;v_map private.legacy_normalized_record_map%rowtype;
 v_supplier_id uuid;v_product_id uuid;v_warehouse_id uuid;v_document_id uuid;v_qty numeric;v_unit_cost numeric;v_date date;v_description text;
 v_imported integer:=0;v_unchanged integer:=0;v_conflicts integer:=0;v_skipped integer:=0;v_invalid integer:=0;v_orphaned integer:=0;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required';end if;
 if p_import_generation is null then raise exception using errcode='22023',message='Import generation UUID is required';end if;
 if not private.has_business_permission(p_business_id,'business.settings.manage') or not private.has_business_permission(p_business_id,'sales.write') or not private.has_business_permission(p_business_id,'catalog.cost.read') then
  raise exception using errcode='42501',message='Purchase import permissions are required';end if;
 perform 1 from public.businesses b where b.id=p_business_id and b.status='active' for update;
 if not found then raise exception using errcode='42501',message='Business is unavailable';end if;
 for v_row in select r.legacy_id,r.payload_public,r.payload_private,r.deleted_at from private.business_state_records r where r.business_id=p_business_id and r.collection='purchases' order by r.legacy_id loop
  if v_row.deleted_at is not null then v_skipped:=v_skipped+1;continue;end if;
  v_legacy_id:=v_row.legacy_id;v_payload:=private.merge_sensitive_json(v_row.payload_public,v_row.payload_private);
  if jsonb_typeof(v_payload)<>'object' or coalesce(v_payload->>'id','')<>v_legacy_id then v_invalid:=v_invalid+1;continue;end if;
  v_fingerprint:=encode(extensions.digest(convert_to(v_payload::text,'UTF8'),'sha256'),'hex');
  select * into v_map from private.legacy_normalized_record_map m where m.business_id=p_business_id and m.legacy_collection='purchases' and m.legacy_id=v_legacy_id for update;
  if found then
   if v_map.import_status<>'mapped' then v_conflicts:=v_conflicts+1;continue;end if;
   if v_map.source_fingerprint<>v_fingerprint then update private.legacy_normalized_record_map set import_status='conflict',note_code='source_changed',last_seen_at=now() where business_id=p_business_id and id=v_map.id;v_conflicts:=v_conflicts+1;continue;end if;
   if not exists(select 1 from public.documents d where d.business_id=p_business_id and d.id=v_map.normalized_id) then update private.legacy_normalized_record_map set import_status='orphaned',note_code='missing_reference',last_seen_at=now() where business_id=p_business_id and id=v_map.id;v_orphaned:=v_orphaned+1;
   else update private.legacy_normalized_record_map set last_seen_at=now() where business_id=p_business_id and id=v_map.id;v_unchanged:=v_unchanged+1;end if;
   continue;
  end if;
  v_supplier_id:=null;v_product_id:=null;v_warehouse_id:=null;v_document_id:=null;v_qty:=null;v_unit_cost:=null;v_date:=null;
  select c.id into v_supplier_id from public.contacts c where c.business_id=p_business_id and c.legacy_id=nullif(v_payload->>'supplierId','') and c.contact_type in ('supplier','both') limit 1;
  select p.id into v_product_id from public.products p where p.business_id=p_business_id and p.legacy_id=nullif(v_payload->>'pid','') limit 1;
  if coalesce(v_payload->>'warehouseId','')<>'' then
   select m.normalized_id into v_warehouse_id from private.legacy_normalized_record_map m where m.business_id=p_business_id and m.legacy_collection='warehouses' and m.legacy_id=v_payload->>'warehouseId' and m.import_status='mapped' limit 1;
   if v_warehouse_id is null then
    begin v_warehouse_id:=(v_payload->>'warehouseId')::uuid;exception when invalid_text_representation then v_warehouse_id:=null;end;
   end if;
  else
   select w.id into v_warehouse_id from public.warehouses w where w.business_id=p_business_id and w.is_active and w.is_default limit 1;
  end if;
  if coalesce(v_payload->>'qty','') !~ '^[0-9]+([.][0-9]{1,4})?$' or coalesce(v_payload->>'unitCost','') !~ '^[0-9]+([.][0-9]+)?$' then v_invalid:=v_invalid+1;continue;end if;
  v_qty:=(v_payload->>'qty')::numeric;v_unit_cost:=(v_payload->>'unitCost')::numeric;
  if v_qty<=0 or v_unit_cost<0 then v_invalid:=v_invalid+1;continue;end if;
  if coalesce(v_payload->>'dt','') ~ '^\d{4}-\d{2}-\d{2}$' then v_date:=(v_payload->>'dt')::date;end if;
  if v_supplier_id is null or v_product_id is null or v_warehouse_id is null or v_date is null then v_skipped:=v_skipped+1;continue;end if;
  if not exists(select 1 from public.warehouses w where w.business_id=p_business_id and w.id=v_warehouse_id and w.is_active) then v_skipped:=v_skipped+1;continue;end if;
  v_description:=coalesce(nullif(v_payload->>'note',''),'خرید واردشده از سوابق اپ');
  v_document_id:=public.create_document_draft(p_business_id,'purchase',v_supplier_id,v_warehouse_id,null,v_date,null,v_description,0,0,
   jsonb_build_array(jsonb_build_object('item_type','goods','product_id',v_product_id,'description',(select p.name from public.products p where p.id=v_product_id),'quantity',v_qty,'unit_name',(select p.unit_name from public.products p where p.id=v_product_id),'unit_price',v_unit_cost,'discount_amount',0,'tax_rate',0)),
   'legacy-import-purchase:'||v_legacy_id);
  insert into private.legacy_normalized_record_map(business_id,legacy_collection,legacy_id,target_table,normalized_id,source_fingerprint,import_status,import_generation,created_by)
  values(p_business_id,'purchases',v_legacy_id,'documents',v_document_id,v_fingerprint,'mapped',p_import_generation,v_user);
  v_imported:=v_imported+1;
 end loop;
 return jsonb_build_object('business_id',p_business_id,'generation',p_import_generation,'mode','purchase_draft_import','imported',v_imported,'unchanged',v_unchanged,'conflicts',v_conflicts,'skipped',v_skipped,'invalid',v_invalid,'orphaned',v_orphaned,'posted',false);
end; $$;

create or replace function public.web_import_legacy_supported_data(p_business_id uuid,p_import_generation uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_preview jsonb;v_reference jsonb;v_suppliers jsonb;v_catalog jsonb;v_fiscal jsonb;v_goods jsonb;v_services jsonb;v_purchases jsonb;v_financial jsonb;v_reconcile jsonb;
begin
 if auth.uid() is null then raise exception using errcode='28000',message='Authentication required';end if;
 if p_import_generation is null then raise exception using errcode='22023',message='Import generation UUID is required';end if;
 if not private.has_business_permission(p_business_id,'business.settings.manage') then raise exception using errcode='42501',message='Business administration permission required';end if;
 v_preview:=public.preview_legacy_normalization(p_business_id);
 if coalesce((v_preview->>'safe_to_import')::boolean,false) is not true then return jsonb_build_object('imported',false,'reason','preflight_not_safe','preflight',v_preview);end if;
 v_reference:=public.import_legacy_reference_data(p_business_id,p_import_generation);
 v_suppliers:=public.import_legacy_supplier_contacts(p_business_id,p_import_generation);
 v_catalog:=public.import_legacy_catalog_and_warehouses(p_business_id,p_import_generation);
 v_fiscal:=public.import_legacy_fiscal_periods(p_business_id,p_import_generation);
 v_goods:=public.import_legacy_goods_invoice_drafts(p_business_id,p_import_generation);
 v_services:=public.import_legacy_service_invoice_drafts(p_business_id,p_import_generation);
 v_purchases:=public.import_legacy_purchase_drafts(p_business_id,p_import_generation);
 v_financial:=public.import_legacy_cash_financial_records(p_business_id,p_import_generation);
 v_reconcile:=public.reconcile_legacy_normalization(p_business_id);
 return jsonb_build_object('imported',true,'generation',p_import_generation,'preflight',v_preview,'reference_import',v_reference,'supplier_import',v_suppliers,'catalog_import',v_catalog,'fiscal_import',v_fiscal,'goods_invoice_import',v_goods,'service_invoice_import',v_services,'purchase_import',v_purchases,'financial_import',v_financial,'reconciliation',v_reconcile,'financial_records_deferred',coalesce((v_financial->>'skipped')::integer,0)>0);
end; $$;
revoke all on function public.import_legacy_purchase_drafts(uuid,uuid) from public,anon;
grant execute on function public.import_legacy_purchase_drafts(uuid,uuid) to authenticated;
revoke all on function public.web_import_legacy_supported_data(uuid,uuid) from public,anon;
grant execute on function public.web_import_legacy_supported_data(uuid,uuid) to authenticated;
commit;