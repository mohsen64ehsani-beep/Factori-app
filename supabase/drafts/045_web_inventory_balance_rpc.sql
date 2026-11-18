begin;
create or replace function public.web_list_inventory_balances(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_rows jsonb;
begin
 if auth.uid() is null then raise exception using errcode='28000',message='Authentication required'; end if;
 if not private.has_business_permission(p_business_id,'inventory.read') then raise exception using errcode='42501',message='Inventory read permission denied'; end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'product_id',x.product_id,'product_name',x.product_name,
  'warehouse_id',x.warehouse_id,'warehouse_name',x.warehouse_name,
  'quantity',x.quantity
 ) order by x.product_name,x.warehouse_name),'[]'::jsonb)
 into v_rows
 from (
  select sm.product_id,p.name as product_name,sm.warehouse_id,w.name as warehouse_name,
   sum(sm.quantity_delta)::numeric(20,4) as quantity
  from public.stock_movements sm
  join public.products p on p.business_id=sm.business_id and p.id=sm.product_id
  join public.warehouses w on w.business_id=sm.business_id and w.id=sm.warehouse_id
  where sm.business_id=p_business_id and p.is_active and p.track_inventory
  group by sm.product_id,p.name,sm.warehouse_id,w.name
  having sum(sm.quantity_delta)<>0
 ) x;
 return v_rows;
end; $$;
revoke all on function public.web_list_inventory_balances(uuid) from public,anon;
grant execute on function public.web_list_inventory_balances(uuid) to authenticated;
commit;