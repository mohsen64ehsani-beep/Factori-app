-- Product costs are sensitive; expose them only through a permission-aware RPC.
revoke select on table public.products from authenticated;
grant select (id,business_id,name,sku,barcode,category_id,unit_name,sale_price,minimum_stock,track_inventory,legacy_id,created_by,is_active,created_at,updated_at,version) on public.products to authenticated;
revoke select (cost_price) on public.products from authenticated;

create or replace function public.web_list_products(p_business_id uuid)
returns table(id uuid,name text,sku text,unit_name text,sale_price numeric,cost_price numeric,category_id uuid,track_inventory boolean,is_active boolean)
language plpgsql security definer set search_path='' as $$
declare v_can_cost boolean;
begin
 if auth.uid() is null then raise exception using errcode='28000',message='Authentication required'; end if;
 if not private.has_business_permission(p_business_id,'catalog.read') then raise exception using errcode='42501',message='Catalog read permission denied'; end if;
 v_can_cost:=private.has_business_permission(p_business_id,'catalog.cost.read');
 return query select p.id,p.name,p.sku,p.unit_name,p.sale_price,
  case when v_can_cost then p.cost_price else null::numeric end,p.category_id,p.track_inventory,p.is_active
 from public.products p where p.business_id=p_business_id and p.is_active order by p.name limit 500;
end; $$;
revoke all on function public.web_list_products(uuid) from public,anon;
grant execute on function public.web_list_products(uuid) to authenticated;

create or replace function public.web_create_product(
 p_business_id uuid,p_name text,p_sku text default null,p_unit_name text default 'عدد',
 p_sale_price numeric default 0,p_track_inventory boolean default true,p_minimum_stock numeric default 0,
 p_barcode text default null,p_cost_price numeric default 0,p_category_id uuid default null
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid();v_legacy_id text:=gen_random_uuid()::text;v_product_id uuid;v_category text;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required'; end if;
 if length(btrim(coalesce(p_name,''))) not between 2 and 160 or coalesce(p_sale_price,0)<0 or coalesce(p_cost_price,0)<0 or coalesce(p_minimum_stock,0)<0 then raise exception using errcode='22023',message='Invalid product details'; end if;
 if not private.has_business_permission(p_business_id,'catalog.write') then raise exception using errcode='42501',message='Catalog write permission denied'; end if;
 if p_cost_price>0 and not private.has_business_permission(p_business_id,'catalog.cost.read') then raise exception using errcode='42501',message='Product cost permission denied'; end if;
 if p_category_id is not null then
  select name into v_category from public.product_categories where id=p_category_id and business_id=p_business_id;
  if v_category is null then raise exception using errcode='22023',message='Invalid product category'; end if;
 end if;
 perform private.assert_feature_limit(p_business_id,'products.total_limit',1);
 perform private.write_legacy_master_record(p_business_id,'prod',v_legacy_id,
  jsonb_strip_nulls(jsonb_build_object('id',v_legacy_id,'n',btrim(p_name),'sku',nullif(btrim(coalesce(p_sku,'')),''),
   'barcode',nullif(btrim(coalesce(p_barcode,'')),''),'sell',coalesce(p_sale_price,0),'buy',coalesce(p_cost_price,0),
   'category',v_category,'minQty',coalesce(p_minimum_stock,0),'unit',coalesce(nullif(btrim(coalesce(p_unit_name,'')),''),'عدد'),
   'track_inventory',coalesce(p_track_inventory,true))),false,v_user);
 select id into v_product_id from public.products where business_id=p_business_id and legacy_id=v_legacy_id;
 if v_product_id is null then raise exception 'Product bridge failed'; end if;
 update public.products set cost_price=coalesce(p_cost_price,0),category_id=p_category_id where business_id=p_business_id and id=v_product_id;
 return v_product_id;
end; $$;
drop function if exists public.web_create_product(uuid,text,text,text,numeric,boolean,numeric,text);
revoke all on function public.web_create_product(uuid,text,text,text,numeric,boolean,numeric,text,numeric,uuid) from public,anon;
grant execute on function public.web_create_product(uuid,text,text,text,numeric,boolean,numeric,text,numeric,uuid) to authenticated;

create or replace function public.web_create_product_category(p_business_id uuid,p_name text,p_parent_id uuid default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;v_name text:=btrim(coalesce(p_name,''));v_legacy_id text;
begin
 if auth.uid() is null then raise exception using errcode='28000',message='Authentication required'; end if;
 if not private.has_business_permission(p_business_id,'catalog.write') then raise exception using errcode='42501',message='Catalog write permission denied'; end if;
 if length(v_name) not between 2 and 100 then raise exception using errcode='22023',message='Invalid category name'; end if;
 if p_parent_id is not null and not exists(select 1 from public.product_categories where id=p_parent_id and business_id=p_business_id) then raise exception using errcode='22023',message='Invalid parent category'; end if;
 v_legacy_id:='value:'||v_name;
 select id into v_id from public.product_categories where business_id=p_business_id and name=v_name limit 1;
 if v_id is null then insert into public.product_categories(business_id,name,parent_id,legacy_id) values(p_business_id,v_name,p_parent_id,v_legacy_id) returning id into v_id;
 else update public.product_categories set legacy_id=coalesce(legacy_id,v_legacy_id),parent_id=coalesce(p_parent_id,parent_id),updated_at=now() where id=v_id; end if;
 perform private.write_legacy_master_record(p_business_id,'categories',v_legacy_id,jsonb_build_object('value',v_name),false,auth.uid());
 return v_id;
end; $$;
revoke all on function public.web_create_product_category(uuid,text,uuid) from public,anon;
grant execute on function public.web_create_product_category(uuid,text,uuid) to authenticated;

-- Mirror legacy Android buy/category fields into normalized products without exposing private cost payloads.
create or replace function private.bridge_legacy_master_to_normalized()
returns trigger language plpgsql security definer set search_path='' as $$
declare
 v_name text;v_phone text;v_address text;v_code text;v_other_active boolean;
 v_sale numeric(20,0);v_minimum numeric(20,4);v_unit text;v_barcode text;v_sku text;v_track boolean;
 v_cost numeric(20,0);v_category text;v_category_id uuid;
begin
 if pg_trigger_depth()>1 then return new; end if;
 if new.collection='cust' then
  v_name:=nullif(btrim(new.payload_public->>'n'),'');v_phone:=nullif(btrim(new.payload_public->>'ph'),'');v_address:=nullif(btrim(new.payload_public->>'ad'),'');v_code:=nullif(btrim(new.payload_public->>'code'),'');
  if v_name is null or length(v_name)>200 then return new; end if;
  select exists(select 1 from private.business_state_records r where r.business_id=new.business_id and r.collection='suppliers' and r.legacy_id=new.legacy_id and r.deleted_at is null) into v_other_active;
  if new.deleted_at is not null then update public.contacts set contact_type=case when v_other_active then 'supplier' else contact_type end,is_active=v_other_active where business_id=new.business_id and legacy_id=new.legacy_id;return new;end if;
  insert into public.contacts(business_id,contact_type,name,phone,address,code,legacy_id,created_by,is_active) values(new.business_id,case when v_other_active then 'both' else 'customer' end,v_name,v_phone,v_address,v_code,new.legacy_id,new.updated_by,true)
  on conflict(business_id,legacy_id) do update set contact_type=case when v_other_active then 'both' else 'customer' end,name=excluded.name,phone=excluded.phone,address=excluded.address,code=coalesce(excluded.code,public.contacts.code),is_active=true;
  return new;
 elsif new.collection='suppliers' then
  v_name:=nullif(btrim(new.payload_public->>'name'),'');v_phone:=nullif(btrim(new.payload_public->>'phone'),'');v_address:=nullif(btrim(new.payload_public->>'address'),'');v_code:=nullif(btrim(new.payload_public->>'code'),'');
  if v_name is null or length(v_name)>200 then return new; end if;
  select exists(select 1 from private.business_state_records r where r.business_id=new.business_id and r.collection='cust' and r.legacy_id=new.legacy_id and r.deleted_at is null) into v_other_active;
  if new.deleted_at is not null then update public.contacts set contact_type=case when v_other_active then 'customer' else contact_type end,is_active=v_other_active where business_id=new.business_id and legacy_id=new.legacy_id;return new;end if;
  insert into public.contacts(business_id,contact_type,name,phone,address,code,legacy_id,created_by,is_active) values(new.business_id,case when v_other_active then 'both' else 'supplier' end,v_name,v_phone,v_address,v_code,new.legacy_id,new.updated_by,true)
  on conflict(business_id,legacy_id) do update set contact_type=case when v_other_active then 'both' else 'supplier' end,name=excluded.name,phone=excluded.phone,address=excluded.address,code=coalesce(excluded.code,public.contacts.code),is_active=true;
  return new;
 elsif new.collection='prod' then
  v_name:=nullif(btrim(new.payload_public->>'n'),'');if v_name is null or length(v_name)>200 then return new;end if;
  if coalesce(new.payload_public->>'sell','') ~ '^[0-9]+([.][0-9]+)?$' then v_sale:=(new.payload_public->>'sell')::numeric(20,0);else v_sale:=0;end if;
  if coalesce(new.payload_public->>'minQty','') ~ '^[0-9]+([.][0-9]{1,4})?$' then v_minimum:=(new.payload_public->>'minQty')::numeric(20,4);else v_minimum:=0;end if;
  if coalesce(new.payload_private->>'buy','') ~ '^[0-9]+([.][0-9]+)?$' then v_cost:=(new.payload_private->>'buy')::numeric(20,0);end if;
  v_category:=nullif(btrim(new.payload_public->>'category'),'');
  select c.id into v_category_id from public.product_categories c where c.business_id=new.business_id and c.name=v_category order by c.created_at limit 1;
  v_unit:=coalesce(nullif(btrim(new.payload_public->>'unit_name'),''),nullif(btrim(new.payload_public->>'unit'),''),'عدد');
  v_barcode:=nullif(btrim(new.payload_public->>'barcode'),'');v_sku:=nullif(btrim(coalesce(new.payload_public->>'sku',new.payload_public->>'code','')),'');
  v_track:=coalesce(nullif(new.payload_public->>'track_inventory','')::boolean,nullif(new.payload_public->>'trackInventory','')::boolean,true);
  if new.deleted_at is not null then update public.products set is_active=false where business_id=new.business_id and legacy_id=new.legacy_id;return new;end if;
  insert into public.products(business_id,name,sku,barcode,sale_price,cost_price,category_id,minimum_stock,unit_name,track_inventory,legacy_id,created_by,is_active)
  values(new.business_id,v_name,v_sku,v_barcode,v_sale,coalesce(v_cost,0),v_category_id,v_minimum,v_unit,v_track,new.legacy_id,new.updated_by,true)
  on conflict(business_id,legacy_id) do update set name=excluded.name,sku=excluded.sku,barcode=excluded.barcode,sale_price=excluded.sale_price,
   cost_price=case when v_cost is not null then v_cost else public.products.cost_price end,category_id=coalesce(v_category_id,public.products.category_id),
   minimum_stock=excluded.minimum_stock,unit_name=excluded.unit_name,track_inventory=excluded.track_inventory,is_active=true;
 end if;
 return new;
end; $$;
