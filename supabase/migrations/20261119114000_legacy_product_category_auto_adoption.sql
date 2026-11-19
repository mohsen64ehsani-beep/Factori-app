CREATE OR REPLACE FUNCTION private.bridge_legacy_master_to_normalized()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
 elsif new.collection='categories' then
  v_name:=nullif(btrim(new.payload_public->>'value'),'');
  if new.deleted_at is not null then return new; end if;
  if v_name is null or length(v_name)>120 or new.legacy_id is distinct from ('value:'||v_name) then return new; end if;
  insert into public.product_categories(business_id,name,legacy_id)
  values(new.business_id,v_name,new.legacy_id)
  on conflict(business_id,name) do update set legacy_id=coalesce(public.product_categories.legacy_id,excluded.legacy_id),updated_at=now();
  update public.products p set category_id=c.id,version=p.version+1,updated_at=now()
  from public.product_categories c
  where c.business_id=new.business_id and c.legacy_id=new.legacy_id
   and p.business_id=new.business_id and p.category_id is null
   and p.name in (select nullif(btrim(r.payload_public->>'n'),'') from private.business_state_records r
    where r.business_id=new.business_id and r.collection='prod' and r.deleted_at is null
     and nullif(btrim(r.payload_public->>'category'),'')=v_name);
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
end; $function$
