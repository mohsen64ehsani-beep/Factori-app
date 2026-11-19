begin;
create or replace function private.publish_document_to_legacy(p_business_id uuid,p_document_id uuid,p_actor uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_doc public.documents%rowtype;v_contact_legacy text;v_items jsonb;v_payload jsonb;v_tax_rate numeric:=0;v_cost_allowed boolean;v_invoice_number bigint:=0;v_item record;v_product_legacy text;v_warehouse_legacy text;v_purchase_id text;
begin
 select * into v_doc from public.documents where business_id=p_business_id and id=p_document_id;
 if not found or v_doc.document_type not in ('goods_sale','service_sale','purchase') then return; end if;
 if coalesce(v_doc.idempotency_key,'') like 'legacy-%' then return; end if;
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
commit;