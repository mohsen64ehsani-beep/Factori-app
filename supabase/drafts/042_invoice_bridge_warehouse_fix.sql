begin;
create or replace function private.publish_sales_document_to_legacy()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_contact_legacy text; v_items jsonb; v_payload jsonb; v_actor uuid; v_tax_rate numeric:=0; v_cost_allowed boolean; v_invoice_number bigint:=0;
begin
 if pg_trigger_depth()>1 or new.document_type<>'goods_sale' then return new; end if;
 if not exists(select 1 from public.document_items i where i.business_id=new.business_id and i.document_id=new.id) then return new; end if;
 select c.legacy_id into v_contact_legacy from public.contacts c where c.business_id=new.business_id and c.id=new.contact_id;
 select coalesce(max(i.tax_rate_snapshot),0) into v_tax_rate from public.document_items i where i.business_id=new.business_id and i.document_id=new.id;
 v_cost_allowed:=private.has_business_permission(new.business_id,'catalog.cost.read');
 select coalesce(jsonb_agg(jsonb_build_object('pid',coalesce(p.legacy_id,i.product_id::text),'n',i.description_snapshot,'q',i.quantity,'p',i.unit_price,'b',case when v_cost_allowed then coalesce(c.unit_cost_snapshot,0) else 0 end) order by i.sort_order),'[]'::jsonb)
 into v_items from public.document_items i
 left join public.products p on p.business_id=i.business_id and p.id=i.product_id
 left join public.document_item_costs c on c.business_id=i.business_id and c.document_item_id=i.id
 where i.business_id=new.business_id and i.document_id=new.id;
 if coalesce(new.document_number,'') ~ '^[0-9]+$' then v_invoice_number:=new.document_number::bigint; end if;
 v_actor:=coalesce(new.created_by,auth.uid());
 v_payload:=jsonb_build_object('id',new.id::text,'no',v_invoice_number,'dt',new.document_date::text,'createdAt',new.created_at::date::text,
 'cid',coalesce(v_contact_legacy,new.contact_id::text),'warehouseId','','bankAccountId','','items',v_items,'ds',new.discount_amount,
 'tx',v_tax_rate,'status',new.status,'notes',coalesce(new.notes,''));
 perform private.write_legacy_master_record(new.business_id,'inv',new.id::text,v_payload,false,v_actor);
 return new;
end;
$$;
commit;