begin;
create or replace function private.write_legacy_master_record(p_business_id uuid,p_collection text,p_legacy_id text,p_payload jsonb,p_deleted boolean,p_actor uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_record_id uuid; v_version bigint; v_existing_payload jsonb; v_deleted_at timestamptz; v_revision bigint; v_change_type text;
begin
 if p_collection not in ('cust','suppliers','prod') or p_legacy_id is null or length(btrim(p_legacy_id)) not between 1 and 200 then
  raise exception using errcode='22023',message='Invalid legacy master record identity';
 end if;
 if not p_deleted and (p_payload is null or jsonb_typeof(p_payload)<>'object' or coalesce(p_payload->>'id','')<>p_legacy_id) then
  raise exception using errcode='22023',message='Invalid legacy master record payload';
 end if;
 if p_deleted then
  update private.business_state_records set deleted_at=now(),version=version+1,updated_at=now(),updated_by=p_actor
  where business_id=p_business_id and collection=p_collection and legacy_id=p_legacy_id and deleted_at is null
  returning id,version into v_record_id,v_version;
  if not found then return; end if;
  v_change_type:='delete';
 else
  select id,version,payload_public,deleted_at into v_record_id,v_version,v_existing_payload,v_deleted_at
  from private.business_state_records where business_id=p_business_id and collection=p_collection and legacy_id=p_legacy_id for update;
  if found then
   if v_existing_payload=p_payload and v_deleted_at is null then return; end if;
   update private.business_state_records set payload_public=p_payload,payload_private='{}'::jsonb,version=v_version+1,updated_at=now(),updated_by=p_actor,deleted_at=null
   where business_id=p_business_id and id=v_record_id returning version into v_version;
  else
   insert into private.business_state_records(business_id,collection,legacy_id,payload_public,payload_private,version,created_at,updated_at,updated_by)
   values(p_business_id,p_collection,p_legacy_id,p_payload,'{}'::jsonb,1,now(),now(),p_actor) returning id,version into v_record_id,v_version;
  end if;
  v_change_type:='upsert';
 end if;
 insert into private.business_sync_counters(business_id,last_revision,updated_at) values(p_business_id,1,now())
 on conflict(business_id) do update set last_revision=private.business_sync_counters.last_revision+1,updated_at=now()
 returning last_revision into v_revision;
 insert into public.record_revisions(business_id,record_type,record_id,revision,changed_by,change_type,change_payload)
 values(p_business_id,p_collection,v_record_id,v_revision,p_actor,v_change_type,jsonb_build_object('legacy_id',p_legacy_id,'version',v_version));
end;
$$;

create or replace function private.bridge_legacy_master_to_normalized()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_name text; v_phone text; v_address text; v_code text; v_other_active boolean; v_sale numeric(20,0); v_minimum numeric(20,4); v_unit text; v_barcode text;
begin
 if pg_trigger_depth()>1 then return new; end if;
 if new.collection='cust' then
  v_name:=nullif(btrim(new.payload_public->>'n'),''); v_phone:=nullif(btrim(new.payload_public->>'ph'),'');
  v_address:=nullif(btrim(new.payload_public->>'ad'),''); v_code:=nullif(btrim(new.payload_public->>'code'),'');
  if v_name is null or length(v_name)>200 then return new; end if;
  select exists(select 1 from private.business_state_records r where r.business_id=new.business_id and r.collection='suppliers' and r.legacy_id=new.legacy_id and r.deleted_at is null) into v_other_active;
  if new.deleted_at is not null then
   update public.contacts set contact_type=case when v_other_active then 'supplier' else contact_type end,is_active=v_other_active
   where business_id=new.business_id and legacy_id=new.legacy_id; return new;
  end if;
  insert into public.contacts(business_id,contact_type,name,phone,address,code,legacy_id,created_by,is_active)
  values(new.business_id,case when v_other_active then 'both' else 'customer' end,v_name,v_phone,v_address,v_code,new.legacy_id,new.updated_by,true)
  on conflict(business_id,legacy_id) do update set contact_type=case when v_other_active then 'both' else 'customer' end,
   name=excluded.name,phone=excluded.phone,address=excluded.address,code=coalesce(excluded.code,public.contacts.code),is_active=true;
  return new;
 elsif new.collection='suppliers' then
  v_name:=nullif(btrim(new.payload_public->>'name'),''); v_phone:=nullif(btrim(new.payload_public->>'phone'),'');
  v_address:=nullif(btrim(new.payload_public->>'address'),''); v_code:=nullif(btrim(new.payload_public->>'code'),'');
  if v_name is null or length(v_name)>200 then return new; end if;
  select exists(select 1 from private.business_state_records r where r.business_id=new.business_id and r.collection='cust' and r.legacy_id=new.legacy_id and r.deleted_at is null) into v_other_active;
  if new.deleted_at is not null then
   update public.contacts set contact_type=case when v_other_active then 'customer' else contact_type end,is_active=v_other_active
   where business_id=new.business_id and legacy_id=new.legacy_id; return new;
  end if;
  insert into public.contacts(business_id,contact_type,name,phone,address,code,legacy_id,created_by,is_active)
  values(new.business_id,case when v_other_active then 'both' else 'supplier' end,v_name,v_phone,v_address,v_code,new.legacy_id,new.updated_by,true)
  on conflict(business_id,legacy_id) do update set contact_type=case when v_other_active then 'both' else 'supplier' end,
   name=excluded.name,phone=excluded.phone,address=excluded.address,code=coalesce(excluded.code,public.contacts.code),is_active=true;
  return new;
 elsif new.collection='prod' then
  v_name:=nullif(btrim(new.payload_public->>'n'),''); if v_name is null or length(v_name)>200 then return new; end if;
  if coalesce(new.payload_public->>'sell','') ~ '^[0-9]+([.][0-9]+)?$' then v_sale:=coalesce((new.payload_public->>'sell')::numeric,0)::numeric(20,0); else v_sale:=0; end if;
  if coalesce(new.payload_public->>'minQty','') ~ '^[0-9]+([.][0-9]{1,4})?$' then v_minimum:=coalesce((new.payload_public->>'minQty')::numeric,0)::numeric(20,4); else v_minimum:=0; end if;
  v_unit:=coalesce(nullif(btrim(new.payload_public->>'unit_name'),''),nullif(btrim(new.payload_public->>'unit'),''),'عدد');
  v_barcode:=nullif(btrim(new.payload_public->>'barcode'),'');
  if new.deleted_at is not null then update public.products set is_active=false where business_id=new.business_id and legacy_id=new.legacy_id; return new; end if;
  insert into public.products(business_id,name,barcode,sale_price,minimum_stock,unit_name,track_inventory,legacy_id,created_by,is_active)
  values(new.business_id,v_name,v_barcode,v_sale,v_minimum,v_unit,true,new.legacy_id,new.updated_by,true)
  on conflict(business_id,legacy_id) do update set name=excluded.name,barcode=excluded.barcode,sale_price=excluded.sale_price,
   minimum_stock=excluded.minimum_stock,unit_name=excluded.unit_name,is_active=true;
 end if;
 return new;
end;
$$;

drop trigger if exists business_state_records_master_bridge on private.business_state_records;
create trigger business_state_records_master_bridge after insert or update on private.business_state_records
for each row when (new.collection in ('cust','suppliers','prod')) execute function private.bridge_legacy_master_to_normalized();

create or replace function public.web_create_contact(p_business_id uuid,p_contact_type text,p_name text,p_phone text default null,p_code text default null,p_address text default null,p_notes text default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_legacy_id text:=gen_random_uuid()::text; v_contact_id uuid;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required'; end if;
 if p_contact_type not in ('customer','supplier','both') or length(btrim(coalesce(p_name,''))) not between 2 and 160 then
  raise exception using errcode='22023',message='Invalid contact details';
 end if;
 if not private.has_business_permission(p_business_id,'contacts.write') then raise exception using errcode='42501',message='Contact write permission denied'; end if;
 if p_contact_type in ('customer','both') then
  perform private.assert_feature_limit(p_business_id,'customers.total_limit',1);
  perform private.write_legacy_master_record(p_business_id,'cust',v_legacy_id,
   jsonb_build_object('id',v_legacy_id,'n',btrim(p_name),'ph',nullif(btrim(coalesce(p_phone,'')),''),'ad',nullif(btrim(coalesce(p_address,'')),''),'code',nullif(btrim(coalesce(p_code,'')),'')),false,v_user);
 end if;
 if p_contact_type in ('supplier','both') then
  perform private.write_legacy_master_record(p_business_id,'suppliers',v_legacy_id,
   jsonb_build_object('id',v_legacy_id,'name',btrim(p_name),'phone',nullif(btrim(coalesce(p_phone,'')),''),'address',nullif(btrim(coalesce(p_address,'')),''),'code',nullif(btrim(coalesce(p_code,'')),'')),false,v_user);
 end if;
 select id into v_contact_id from public.contacts where business_id=p_business_id and legacy_id=v_legacy_id;
 if v_contact_id is null then raise exception 'Contact bridge failed'; end if;
 if p_notes is not null and btrim(p_notes)<>'' then update public.contacts set notes=left(btrim(p_notes),2000) where business_id=p_business_id and id=v_contact_id; end if;
 return v_contact_id;
end;
$$;

create or replace function public.web_create_product(p_business_id uuid,p_name text,p_sku text default null,p_unit_name text default 'عدد',p_sale_price numeric default 0,p_track_inventory boolean default true,p_minimum_stock numeric default 0,p_barcode text default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_legacy_id text:=gen_random_uuid()::text; v_product_id uuid;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required'; end if;
 if length(btrim(coalesce(p_name,''))) not between 2 and 160 or coalesce(p_sale_price,0)<0 or coalesce(p_minimum_stock,0)<0 then
  raise exception using errcode='22023',message='Invalid product details';
 end if;
 if not private.has_business_permission(p_business_id,'catalog.write') then raise exception using errcode='42501',message='Catalog write permission denied'; end if;
 perform private.assert_feature_limit(p_business_id,'products.total_limit',1);
 perform private.write_legacy_master_record(p_business_id,'prod',v_legacy_id,
  jsonb_build_object('id',v_legacy_id,'n',btrim(p_name),'barcode',nullif(btrim(coalesce(p_barcode,'')),''),'sell',coalesce(p_sale_price,0),
   'minQty',coalesce(p_minimum_stock,0),'unit',coalesce(nullif(btrim(coalesce(p_unit_name,'')),''),'عدد')),false,v_user);
 select id into v_product_id from public.products where business_id=p_business_id and legacy_id=v_legacy_id;
 if v_product_id is null then raise exception 'Product bridge failed'; end if;
 return v_product_id;
end;
$$;

revoke insert,update,delete on public.contacts,public.products,public.services from authenticated,anon,public;
revoke insert (business_id,contact_type,name,phone,code,address,notes,is_active,created_by),
 update (contact_type,name,phone,code,address,notes,is_active) on public.contacts from authenticated;
revoke insert (business_id,category_id,name,sku,barcode,unit_name,sale_price,track_inventory,minimum_stock,is_active,created_by),
 update (category_id,name,sku,barcode,unit_name,sale_price,track_inventory,minimum_stock,is_active) on public.products from authenticated;
revoke insert (business_id,name,description,sale_price,is_active,created_by),
 update (name,description,sale_price,is_active) on public.services from authenticated;
revoke all on function private.write_legacy_master_record(uuid,text,text,jsonb,boolean,uuid) from public,anon,authenticated;
revoke all on function private.bridge_legacy_master_to_normalized() from public,anon,authenticated;
revoke all on function public.web_create_contact(uuid,text,text,text,text,text,text) from public,anon;
revoke all on function public.web_create_product(uuid,text,text,text,numeric,boolean,numeric,text) from public,anon;
grant execute on function public.web_create_contact(uuid,text,text,text,text,text,text) to authenticated;
grant execute on function public.web_create_product(uuid,text,text,text,numeric,boolean,numeric,text) to authenticated;
commit;