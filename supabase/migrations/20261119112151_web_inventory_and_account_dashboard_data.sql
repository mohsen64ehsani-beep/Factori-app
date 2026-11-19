drop function if exists public.web_list_products(uuid);
create function public.web_list_products(p_business_id uuid)
returns table(id uuid,name text,sku text,unit_name text,sale_price numeric,cost_price numeric,category_id uuid,track_inventory boolean,is_active boolean,minimum_stock numeric)
language plpgsql security definer set search_path='' as $$
declare v_can_cost boolean;
begin
 if auth.uid() is null then raise exception using errcode='28000',message='Authentication required'; end if;
 if not private.has_business_permission(p_business_id,'catalog.read') then raise exception using errcode='42501',message='Catalog read permission denied'; end if;
 v_can_cost:=private.has_business_permission(p_business_id,'catalog.cost.read');
 return query select p.id,p.name,p.sku,p.unit_name,p.sale_price,
  case when v_can_cost then p.cost_price else null::numeric end,p.category_id,p.track_inventory,p.is_active,p.minimum_stock
 from public.products p where p.business_id=p_business_id and p.is_active order by p.name limit 500;
end; $$;
revoke all on function public.web_list_products(uuid) from public,anon;
grant execute on function public.web_list_products(uuid) to authenticated;
