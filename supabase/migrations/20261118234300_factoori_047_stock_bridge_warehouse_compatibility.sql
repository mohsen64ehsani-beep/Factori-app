begin;
create or replace function private.publish_stock_movement_to_legacy()
returns trigger language plpgsql security definer set search_path='' as $$
declare
 v_product_legacy text;v_product_name text;v_sale_price numeric;v_unit text;
 v_before numeric(20,4);v_after numeric(20,4);v_payload jsonb;v_product_payload jsonb;v_actor uuid;v_total numeric(20,4);
begin
 if pg_trigger_depth()>1 then return new; end if;
 select p.legacy_id,p.name,p.sale_price,p.unit_name into v_product_legacy,v_product_name,v_sale_price,v_unit
 from public.products p where p.business_id=new.business_id and p.id=new.product_id;
 if v_product_legacy is null then v_product_legacy:=new.product_id::text; end if;
 select coalesce(sum(sm.quantity_delta),0)-new.quantity_delta into v_before from public.stock_movements sm
 where sm.business_id=new.business_id and sm.product_id=new.product_id and sm.warehouse_id=new.warehouse_id;
 v_after:=v_before+new.quantity_delta;v_actor:=coalesce(new.created_by,auth.uid());
 v_payload:=jsonb_build_object('id',new.id::text,'pid',v_product_legacy,'dt',new.movement_date::date::text,
  'delta',new.quantity_delta,'before',v_before,'after',v_after,'reason',coalesce(new.note,new.movement_type),
  'warehouseId',new.warehouse_id::text);
 perform private.write_legacy_master_record(new.business_id,'stockMoves',new.id::text,v_payload,false,v_actor);
 select coalesce(sum(sm.quantity_delta),0) into v_total from public.stock_movements sm
 where sm.business_id=new.business_id and sm.product_id=new.product_id;
 select r.payload_public into v_product_payload from private.business_state_records r
 where r.business_id=new.business_id and r.collection='prod' and r.legacy_id=v_product_legacy and r.deleted_at is null;
 if v_product_payload is not null then
  v_product_payload:=jsonb_set(v_product_payload,'{qty}',to_jsonb(v_total),true);
 else
  v_product_payload:=jsonb_build_object('id',v_product_legacy,'n',v_product_name,'sell',coalesce(v_sale_price,0),'unit_name',coalesce(v_unit,'عدد'),'qty',v_total);
 end if;
 perform private.write_legacy_master_record(new.business_id,'prod',v_product_legacy,v_product_payload,false,v_actor);
 return new;
end; $$;
commit;