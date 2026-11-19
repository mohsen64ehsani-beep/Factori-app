alter table public.products
  add column if not exists cost_price numeric not null default 0
  check (cost_price >= 0);

create or replace function public.web_create_product(
 p_business_id uuid, p_name text, p_sku text default null, p_unit_name text default 'عدد',
 p_sale_price numeric default 0, p_track_inventory boolean default true,
 p_minimum_stock numeric default 0, p_barcode text default null,
 p_cost_price numeric default 0, p_category_id uuid default null
) returns uuid language plpgsql security definer set search_path = '' as $function$
declare v_user uuid:=auth.uid(); v_legacy_id text:=gen_random_uuid()::text; v_product_id uuid;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required'; end if;
 if length(btrim(coalesce(p_name,''))) not between 2 and 160
   or coalesce(p_sale_price,0)<0 or coalesce(p_cost_price,0)<0 or coalesce(p_minimum_stock,0)<0 then
  raise exception using errcode='22023',message='Invalid product details';
 end if;
 if not private.has_business_permission(p_business_id,'catalog.write') then raise exception using errcode='42501',message='Catalog write permission denied'; end if;
 if p_category_id is not null and not exists(select 1 from public.product_categories c where c.id=p_category_id and c.business_id=p_business_id) then
  raise exception using errcode='22023',message='Invalid product category';
 end if;
 perform private.assert_feature_limit(p_business_id,'products.total_limit',1);
 perform private.write_legacy_master_record(p_business_id,'prod',v_legacy_id,
  jsonb_build_object('id',v_legacy_id,'n',btrim(p_name),'sku',nullif(btrim(coalesce(p_sku,'')),''),
   'barcode',nullif(btrim(coalesce(p_barcode,'')),''),'sell',coalesce(p_sale_price,0),
   'minQty',coalesce(p_minimum_stock,0),'unit',coalesce(nullif(btrim(coalesce(p_unit_name,'')),''),'عدد'),
   'track_inventory',coalesce(p_track_inventory,true)),false,v_user);
 select id into v_product_id from public.products where business_id=p_business_id and legacy_id=v_legacy_id;
 if v_product_id is null then raise exception 'Product bridge failed'; end if;
 update public.products set cost_price=coalesce(p_cost_price,0),category_id=p_category_id where business_id=p_business_id and id=v_product_id;
 return v_product_id;
end;
$function$;

create or replace function public.web_create_product_category(p_business_id uuid,p_name text,p_parent_id uuid default null)
returns uuid language plpgsql security definer set search_path='' as $function$
declare v_id uuid; v_name text:=btrim(coalesce(p_name,''));
begin
 if auth.uid() is null then raise exception using errcode='28000',message='Authentication required'; end if;
 if not private.has_business_permission(p_business_id,'catalog.write') then raise exception using errcode='42501',message='Catalog write permission denied'; end if;
 if length(v_name) not between 2 and 100 then raise exception using errcode='22023',message='Invalid category name'; end if;
 if p_parent_id is not null and not exists(select 1 from public.product_categories where id=p_parent_id and business_id=p_business_id) then raise exception using errcode='22023',message='Invalid parent category'; end if;
 insert into public.product_categories(business_id,name,parent_id) values(p_business_id,v_name,p_parent_id) returning id into v_id;
 return v_id;
end;
$function$;

revoke all on function public.web_create_product_category(uuid,text,uuid) from public,anon;
grant execute on function public.web_create_product_category(uuid,text,uuid) to authenticated;
