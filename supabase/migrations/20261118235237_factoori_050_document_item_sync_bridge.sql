begin;
create or replace function private.publish_document_to_legacy(p_business_id uuid,p_document_id uuid,p_actor uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_doc public.documents%rowtype;v_contact_legacy text;v_items jsonb;v_payload jsonb;v_tax_rate numeric:=0;v_cost_allowed boolean;v_collection text;v_invoice_number bigint:=0;
begin
 select * into v_doc from public.documents where business_id=p_business_id and id=p_document_id;
 if not found or v_doc.document_type not in ('goods_sale','service_sale') then return; end if;
 if not exists(select 1 from public.document_items i where i.business_id=p_business_id and i.document_id=p_document_id) then return; end if;
 select c.legacy_id into v_contact_legacy from public.contacts c where c.business_id=p_business_id and c.id=v_doc.contact_id;
 select coalesce(max(i.tax_rate_snapshot),0) into v_tax_rate from public.document_items i where i.business_id=p_business_id and i.document_id=p_document_id;
 v_cost_allowed:=private.has_business_permission(p_business_id,'catalog.cost.read');
 if coalesce(v_doc.document_number,'') ~ '^[0-9]+$' then v_invoice_number:=v_doc.document_number::bigint; end if;
 if v_doc.document_type='goods_sale' then
  v_collection:='inv';
  select coalesce(jsonb_agg(jsonb_build_object('pid',coalesce(p.legacy_id,i.product_id::text),'n',i.description_snapshot,'q',i.quantity,'p',i.unit_price,'b',case when v_cost_allowed then coalesce(c.unit_cost_snapshot,0) else 0 end) order by i.sort_order),'[]'::jsonb)
  into v_items from public.document_items i left join public.products p on p.business_id=i.business_id and p.id=i.product_id
  left join public.document_item_costs c on c.business_id=i.business_id and c.document_item_id=i.id
  where i.business_id=p_business_id and i.document_id=p_document_id;
  v_payload:=jsonb_build_object('id',v_doc.id::text,'no',v_invoice_number,'dt',v_doc.document_date::text,'createdAt',v_doc.created_at::date::text,
   'cid',coalesce(v_contact_legacy,v_doc.contact_id::text),'warehouseId','','bankAccountId','','items',v_items,'ds',v_doc.discount_amount,
   'tx',v_tax_rate,'status',v_doc.status,'notes',coalesce(v_doc.notes,''));
 else
  v_collection:='serviceInv';
  select coalesce(jsonb_agg(jsonb_build_object('desc',i.description_snapshot,'qty',i.quantity,'price',i.unit_price,'cost',case when v_cost_allowed then coalesce(c.unit_cost_snapshot,0) else 0 end) order by i.sort_order),'[]'::jsonb)
  into v_items from public.document_items i left join public.document_item_costs c on c.business_id=i.business_id and c.document_item_id=i.id
  where i.business_id=p_business_id and i.document_id=p_document_id;
  v_payload:=jsonb_build_object('id',v_doc.id::text,'no',v_invoice_number,'dt',v_doc.document_date::text,'createdAt',v_doc.created_at::date::text,
   'cid',coalesce(v_contact_legacy,v_doc.contact_id::text),'bankAccountId','','items',v_items,'discount',v_doc.discount_amount,
   'costMode','row','costTotal',0,'status',v_doc.status);
 end if;
 perform private.write_legacy_master_record(p_business_id,v_collection,v_doc.id::text,v_payload,false,coalesce(p_actor,v_doc.created_by,auth.uid()));
end; $$;

create or replace function private.publish_sales_document_to_legacy()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if pg_trigger_depth()>1 then return new; end if;
 perform private.publish_document_to_legacy(new.business_id,new.id,coalesce(new.created_by,auth.uid()));
 return new;
end; $$;

create or replace function private.publish_document_items_to_legacy()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_business_id uuid;v_document_id uuid;v_actor uuid;
begin
 if tg_op='DELETE' then v_business_id:=old.business_id;v_document_id:=old.document_id;else v_business_id:=new.business_id;v_document_id:=new.document_id;end if;
 select created_by into v_actor from public.documents where business_id=v_business_id and id=v_document_id;
 perform private.publish_document_to_legacy(v_business_id,v_document_id,coalesce(v_actor,auth.uid()));
 if tg_op='DELETE' then return old;else return new;end if;
end; $$;
drop trigger if exists document_items_publish_legacy on public.document_items;
create trigger document_items_publish_legacy after insert or update or delete on public.document_items
for each row execute function private.publish_document_items_to_legacy();
revoke all on function private.publish_document_to_legacy(uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function private.publish_document_items_to_legacy() from public,anon,authenticated;
commit;