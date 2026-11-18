begin;
create or replace function private.bridge_legacy_master_to_normalized()
returns trigger language plpgsql security definer set search_path='' as $$
declare
 v_name text; v_phone text; v_address text; v_code text; v_other_active boolean;
 v_sale numeric(20,0); v_minimum numeric(20,4); v_unit text; v_barcode text; v_sku text; v_track boolean;
begin
 if pg_trigger_depth()>1 then return new; end if;
 if new.collection='cust' then
  v_name:=nullif(btrim(new.payload_public->>'n'),''); v_phone:=nullif(btrim(new.payload_public->>'ph'),'');
  v_address:=nullif(btrim(new.payload_public->>'ad'),''); v_code:=nullif(btrim(new.payload_public->>'code'),'');
  if v_name is null or length(v_name)>200 then return new; end if;
  select exists(select 1 from private.business_state_records r where r.business_id=new.business_id and r.collection='suppliers' and r.legacy_id=new.legacy_id and r.deleted_at is null) into v_other_active;
  if new.deleted_at is not null then
   update public.contacts set contact_type=case when v_other_active then 'supplier' else contact_type end,is_active=v_other_active where business_id=new.business_id and legacy_id=new.legacy_id; return new;
  end if;
  insert into public.contacts(business_id,contact_type,name,phone,address,code,legacy_id,created_by,is_active)
  values(new.business_id,case when v_other_active then 'both' else 'customer' end,v_name,v_phone,v_address,v_code,new.legacy_id,new.updated_by,true)
  on conflict(business_id,legacy_id) do update set contact_type=case when v_other_active then 'both' else 'customer' end,name=excluded.name,phone=excluded.phone,address=excluded.address,code=coalesce(excluded.code,public.contacts.code),is_active=true;
  return new;
 elsif new.collection='suppliers' then
  v_name:=nullif(btrim(new.payload_public->>'name'),''); v_phone:=nullif(btrim(new.payload_public->>'phone'),'');
  v_address:=nullif(btrim(new.payload_public->>'address'),''); v_code:=nullif(btrim(new.payload_public->>'code'),'');
  if v_name is null or length(v_name)>200 then return new; end if;
  select exists(select 1 from private.business_state_records r where r.business_id=new.business_id and r.collection='cust' and r.legacy_id=new.legacy_id and r.deleted_at is null) into v_other_active;
  if new.deleted_at is not null then
   update public.contacts set contact_type=case when v_other_active then 'customer' else contact_type end,is_active=v_other_active where business_id=new.business_id and legacy_id=new.legacy_id; return new;
  end if;
  insert into public.contacts(business_id,contact_type,name,phone,address,code,legacy_id,created_by,is_active)
  values(new.business_id,case when v_other_active then 'both' else 'supplier' end,v_name,v_phone,v_address,v_code,new.legacy_id,new.updated_by,true)
  on conflict(business_id,legacy_id) do update set contact_type=case when v_other_active then 'both' else 'supplier' end,name=excluded.name,phone=excluded.phone,address=excluded.address,code=coalesce(excluded.code,public.contacts.code),is_active=true;
  return new;
 elsif new.collection='prod' then
  v_name:=nullif(btrim(new.payload_public->>'n'),''); if v_name is null or length(v_name)>200 then return new; end if;
  if coalesce(new.payload_public->>'sell','') ~ '^[0-9]+([.][0-9]+)?$' then v_sale:=coalesce((new.payload_public->>'sell')::numeric,0)::numeric(20,0); else v_sale:=0; end if;
  if coalesce(new.payload_public->>'minQty','') ~ '^[0-9]+([.][0-9]{1,4})?$' then v_minimum:=coalesce((new.payload_public->>'minQty')::numeric,0)::numeric(20,4); else v_minimum:=0; end if;
  v_unit:=coalesce(nullif(btrim(new.payload_public->>'unit_name'),''),nullif(btrim(new.payload_public->>'unit'),''),'عدد');
  v_barcode:=nullif(btrim(new.payload_public->>'barcode'),'');
  v_sku:=nullif(btrim(coalesce(new.payload_public->>'sku',new.payload_public->>'code','')),'');
  v_track:=coalesce(nullif(new.payload_public->>'track_inventory','')::boolean,nullif(new.payload_public->>'trackInventory','')::boolean,true);
  if new.deleted_at is not null then update public.products set is_active=false where business_id=new.business_id and legacy_id=new.legacy_id; return new; end if;
  insert into public.products(business_id,name,sku,barcode,sale_price,minimum_stock,unit_name,track_inventory,legacy_id,created_by,is_active)
  values(new.business_id,v_name,v_sku,v_barcode,v_sale,v_minimum,v_unit,v_track,new.legacy_id,new.updated_by,true)
  on conflict(business_id,legacy_id) do update set name=excluded.name,sku=excluded.sku,barcode=excluded.barcode,sale_price=excluded.sale_price,minimum_stock=excluded.minimum_stock,unit_name=excluded.unit_name,track_inventory=excluded.track_inventory,is_active=true;
 end if;
 return new;
end;
$$;
create or replace function public.web_create_product(p_business_id uuid,p_name text,p_sku text default null,p_unit_name text default 'عدد',p_sale_price numeric default 0,p_track_inventory boolean default true,p_minimum_stock numeric default 0,p_barcode text default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_legacy_id text:=gen_random_uuid()::text; v_product_id uuid;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required'; end if;
 if length(btrim(coalesce(p_name,''))) not between 2 and 160 or coalesce(p_sale_price,0)<0 or coalesce(p_minimum_stock,0)<0 then raise exception using errcode='22023',message='Invalid product details'; end if;
 if not private.has_business_permission(p_business_id,'catalog.write') then raise exception using errcode='42501',message='Catalog write permission denied'; end if;
 perform private.assert_feature_limit(p_business_id,'products.total_limit',1);
 perform private.write_legacy_master_record(p_business_id,'prod',v_legacy_id,jsonb_build_object('id',v_legacy_id,'n',btrim(p_name),'sku',nullif(btrim(coalesce(p_sku,'')),''),'barcode',nullif(btrim(coalesce(p_barcode,'')),''),'sell',coalesce(p_sale_price,0),'minQty',coalesce(p_minimum_stock,0),'unit',coalesce(nullif(btrim(coalesce(p_unit_name,'')),''),'عدد'),'track_inventory',coalesce(p_track_inventory,true)),false,v_user);
 select id into v_product_id from public.products where business_id=p_business_id and legacy_id=v_legacy_id;
 if v_product_id is null then raise exception 'Product bridge failed'; end if;
 return v_product_id;
end;
$$;
commit;