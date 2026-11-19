-- 024: Safe reference-data import for legacy customers and products only.
-- Does not import product costs, stock balances, documents, payments or tombstones.
begin;

create or replace function public.import_legacy_reference_data(
 p_business_id uuid,
 p_import_generation uuid
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
 v_user uuid:=auth.uid();
 v_row record;
 v_payload jsonb;
 v_legacy_id text;
 v_name text;
 v_fingerprint text;
 v_map private.legacy_normalized_record_map%rowtype;
 v_target_id uuid;
 v_phone text;
 v_address text;
 v_code text;
 v_barcode text;
 v_sale_price numeric(20,0);
 v_minimum_stock numeric(20,4);
 v_imported_customers integer:=0;
 v_imported_products integer:=0;
 v_unchanged integer:=0;
 v_conflicts integer:=0;
 v_invalid integer:=0;
 v_orphaned integer:=0;
 v_deleted integer:=0;
begin
 if v_user is null then
  raise exception using errcode='28000',message='Authentication required';
 end if;
 if p_import_generation is null then
  raise exception using errcode='22023',message='Import generation UUID is required';
 end if;
 if not private.has_business_permission(p_business_id,'business.settings.manage')
   or not private.has_business_permission(p_business_id,'contacts.write')
   or not private.has_business_permission(p_business_id,'catalog.write') then
  raise exception using errcode='42501',message='Business owner import permissions are required';
 end if;

 perform 1 from public.businesses b where b.id=p_business_id and b.status='active' for update;
 if not found then
  raise exception using errcode='42501',message='Business is unavailable';
 end if;

 -- Only public payload is read. Sensitive product cost fields remain in the private
 -- payload and are intentionally excluded from this first reference-data pass.
 for v_row in
  select r.collection,r.legacy_id,r.payload_public,r.deleted_at
  from private.business_state_records r
  where r.business_id=p_business_id and r.collection in ('cust','prod')
  order by case r.collection when 'cust' then 1 else 2 end,r.legacy_id
 loop
  if v_row.deleted_at is not null then
   v_deleted:=v_deleted+1;
   continue;
  end if;
  v_payload:=v_row.payload_public;
  v_legacy_id:=v_row.legacy_id;
  if jsonb_typeof(v_payload)<>'object'
    or coalesce(v_payload->>'id','')<>v_legacy_id
    or length(btrim(v_legacy_id)) not between 1 and 200 then
   v_invalid:=v_invalid+1;
   continue;
  end if;
  v_name:=nullif(btrim(v_payload->>'n'),'');
  if v_name is null or length(v_name)>200 then
   v_invalid:=v_invalid+1;
   continue;
  end if;
  v_fingerprint:=encode(extensions.digest(convert_to(v_payload::text,'UTF8'),'sha256'),'hex');

  select * into v_map from private.legacy_normalized_record_map m
  where m.business_id=p_business_id and m.legacy_collection=v_row.collection
    and m.legacy_id=v_legacy_id for update;
  if found then
   if v_map.import_status<>'mapped' then
    v_conflicts:=v_conflicts+1;
    update private.legacy_normalized_record_map
    set last_seen_at=now() where business_id=p_business_id and id=v_map.id;
    continue;
   end if;
   if v_map.source_fingerprint<>v_fingerprint then
    update private.legacy_normalized_record_map
    set import_status='conflict',note_code='source_changed',last_seen_at=now()
    where business_id=p_business_id and id=v_map.id;
    v_conflicts:=v_conflicts+1;
    continue;
   end if;
   if v_row.collection='cust' and not exists(
    select 1 from public.contacts c where c.business_id=p_business_id and c.id=v_map.normalized_id
   ) then
    update private.legacy_normalized_record_map
    set import_status='orphaned',note_code='missing_reference',last_seen_at=now()
    where business_id=p_business_id and id=v_map.id;
    v_orphaned:=v_orphaned+1;
   elsif v_row.collection='prod' and not exists(
    select 1 from public.products p where p.business_id=p_business_id and p.id=v_map.normalized_id
   ) then
    update private.legacy_normalized_record_map
    set import_status='orphaned',note_code='missing_reference',last_seen_at=now()
    where business_id=p_business_id and id=v_map.id;
    v_orphaned:=v_orphaned+1;
   else
    update private.legacy_normalized_record_map
    set last_seen_at=now() where business_id=p_business_id and id=v_map.id;
    v_unchanged:=v_unchanged+1;
   end if;
   continue;
  end if;

  if v_row.collection='cust' then
   v_phone:=nullif(btrim(v_payload->>'ph'),'');
   v_address:=nullif(btrim(v_payload->>'ad'),'');
   v_code:=nullif(btrim(v_payload->>'code'),'');
   select c.id into v_target_id from public.contacts c
   where c.business_id=p_business_id and c.legacy_id=v_legacy_id;
   if v_target_id is not null then
    if exists(select 1 from public.contacts c where c.business_id=p_business_id and c.id=v_target_id
      and c.contact_type='customer' and c.name=v_name and c.phone is not distinct from v_phone
      and c.address is not distinct from v_address and c.code is not distinct from v_code) then
     insert into private.legacy_normalized_record_map(business_id,legacy_collection,legacy_id,target_table,normalized_id,source_fingerprint,import_status,import_generation,created_by)
     values(p_business_id,'cust',v_legacy_id,'contacts',v_target_id,v_fingerprint,'mapped',p_import_generation,v_user);
     v_imported_customers:=v_imported_customers+1;
    else
     insert into private.legacy_normalized_record_map(business_id,legacy_collection,legacy_id,target_table,normalized_id,source_fingerprint,import_status,import_generation,note_code,created_by)
     values(p_business_id,'cust',v_legacy_id,'contacts',v_target_id,v_fingerprint,'conflict',p_import_generation,'target_conflict',v_user);
     v_conflicts:=v_conflicts+1;
    end if;
    continue;
   end if;
   begin
    insert into public.contacts(business_id,contact_type,name,phone,address,code,legacy_id,created_by)
    values(p_business_id,'customer',v_name,v_phone,v_address,v_code,v_legacy_id,v_user)
    returning id into v_target_id;
   exception when unique_violation or check_violation or string_data_right_truncation then
    v_invalid:=v_invalid+1;
    continue;
   end;
   insert into private.legacy_normalized_record_map(
    business_id,legacy_collection,legacy_id,target_table,normalized_id,
    source_fingerprint,import_status,import_generation,created_by
   ) values (
    p_business_id,'cust',v_legacy_id,'contacts',v_target_id,
    v_fingerprint,'mapped',p_import_generation,v_user
   );
   v_imported_customers:=v_imported_customers+1;
  else
   v_barcode:=nullif(btrim(v_payload->>'barcode'),'');
   if v_payload ? 'sell' and coalesce(v_payload->>'sell','') !~ '^[0-9]+([.][0-9]+)?$' then
    v_invalid:=v_invalid+1; continue;
   end if;
   if v_payload ? 'minQty' and coalesce(v_payload->>'minQty','') !~ '^[0-9]+([.][0-9]{1,4})?$' then
    v_invalid:=v_invalid+1; continue;
   end if;
   begin
    v_sale_price:=coalesce(nullif(v_payload->>'sell','')::numeric,0)::numeric(20,0);
    v_minimum_stock:=coalesce(nullif(v_payload->>'minQty','')::numeric,0)::numeric(20,4);
   exception when numeric_value_out_of_range or invalid_text_representation then
    v_invalid:=v_invalid+1; continue;
   end;
   if v_sale_price<0 or v_minimum_stock<0 then v_invalid:=v_invalid+1; continue; end if;
   select p.id into v_target_id from public.products p
   where p.business_id=p_business_id and p.legacy_id=v_legacy_id;
   if v_target_id is not null then
    if exists(select 1 from public.products p where p.business_id=p_business_id and p.id=v_target_id
      and p.name=v_name and p.barcode is not distinct from v_barcode and p.sale_price=v_sale_price
      and p.minimum_stock=v_minimum_stock and p.track_inventory=true) then
     insert into private.legacy_normalized_record_map(business_id,legacy_collection,legacy_id,target_table,normalized_id,source_fingerprint,import_status,import_generation,created_by)
     values(p_business_id,'prod',v_legacy_id,'products',v_target_id,v_fingerprint,'mapped',p_import_generation,v_user);
     v_imported_products:=v_imported_products+1;
    else
     insert into private.legacy_normalized_record_map(business_id,legacy_collection,legacy_id,target_table,normalized_id,source_fingerprint,import_status,import_generation,note_code,created_by)
     values(p_business_id,'prod',v_legacy_id,'products',v_target_id,v_fingerprint,'conflict',p_import_generation,'target_conflict',v_user);
     v_conflicts:=v_conflicts+1;
    end if;
    continue;
   end if;
   begin
    insert into public.products(
     business_id,name,barcode,sale_price,minimum_stock,track_inventory,legacy_id,created_by
    ) values (
     p_business_id,v_name,v_barcode,v_sale_price,v_minimum_stock,true,v_legacy_id,v_user
    ) returning id into v_target_id;
   exception when unique_violation then
    v_conflicts:=v_conflicts+1;
    continue;
   when check_violation or string_data_right_truncation or numeric_value_out_of_range then
    v_invalid:=v_invalid+1;
    continue;
   end;
   insert into private.legacy_normalized_record_map(
    business_id,legacy_collection,legacy_id,target_table,normalized_id,
    source_fingerprint,import_status,import_generation,created_by
   ) values (
    p_business_id,'prod',v_legacy_id,'products',v_target_id,
    v_fingerprint,'mapped',p_import_generation,v_user
   );
   v_imported_products:=v_imported_products+1;
  end if;
 end loop;

 return jsonb_build_object(
  'business_id',p_business_id,'generation',p_import_generation,
  'mode','reference_data_import','source_collections',jsonb_build_array('cust','prod'),
  'imported_customers',v_imported_customers,'imported_products',v_imported_products,
  'unchanged',v_unchanged,'conflicts',v_conflicts,'invalid',v_invalid,
  'orphaned_mappings',v_orphaned,'deleted_source_rows_skipped',v_deleted,
  'stock_quantities_imported',false,'product_costs_imported',false,
  'documents_imported',false,'financial_data_imported',false
 );
end;
$$;

revoke all on function public.import_legacy_reference_data(uuid,uuid) from public,anon;
grant execute on function public.import_legacy_reference_data(uuid,uuid) to authenticated;

commit;
