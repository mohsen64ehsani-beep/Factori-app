-- 025: Import legacy categories, services and warehouses after source-shape validation.
-- No stock balances, movement history, financial records or sensitive payloads are imported.
begin;

create or replace function public.import_legacy_catalog_and_warehouses(
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
 v_address text;
 v_fingerprint text;
 v_map private.legacy_normalized_record_map%rowtype;
 v_target_id uuid;
 v_is_default boolean;
 v_imported_categories integer:=0;
 v_imported_services integer:=0;
 v_imported_warehouses integer:=0;
 v_unchanged integer:=0;
 v_conflicts integer:=0;
 v_invalid integer:=0;
 v_orphaned integer:=0;
 v_deleted integer:=0;
 v_categorized integer:=0;
 v_unmapped_categories integer:=0;
begin
 if v_user is null then
  raise exception using errcode='28000',message='Authentication required';
 end if;
 if p_import_generation is null then
  raise exception using errcode='22023',message='Import generation UUID is required';
 end if;
 if not private.has_business_permission(p_business_id,'business.settings.manage')
   or not private.has_business_permission(p_business_id,'catalog.write')
   or not private.has_business_permission(p_business_id,'inventory.adjust') then
  raise exception using errcode='42501',message='Business administration, catalog and inventory permissions are required';
 end if;
 perform 1 from public.businesses b where b.id=p_business_id and b.status='active' for update;
 if not found then
  raise exception using errcode='42501',message='Business is unavailable';
 end if;

 for v_row in
  select r.collection,r.legacy_id,r.payload_public,r.deleted_at
  from private.business_state_records r
  where r.business_id=p_business_id and r.collection in ('categories','services','warehouses')
  order by case r.collection when 'categories' then 1 when 'services' then 2 else 3 end,r.legacy_id
 loop
  if v_row.deleted_at is not null then
   v_deleted:=v_deleted+1;
   continue;
  end if;
  v_payload:=v_row.payload_public;
  v_legacy_id:=v_row.legacy_id;
  if jsonb_typeof(v_payload)<>'object' then
   v_invalid:=v_invalid+1; continue;
  end if;

  if v_row.collection in ('categories','services') then
   v_name:=nullif(btrim(v_payload->>'value'),'');
   if v_name is null or length(v_name)>case when v_row.collection='categories' then 120 else 200 end
     or ('value:'||v_name) is distinct from v_legacy_id then
    v_invalid:=v_invalid+1; continue;
   end if;
  else
   v_name:=nullif(btrim(v_payload->>'name'),'');
   v_address:=nullif(btrim(v_payload->>'address'),'');
   if v_name is null or length(v_name)>120 or coalesce(v_payload->>'id','')<>v_legacy_id then
    v_invalid:=v_invalid+1; continue;
   end if;
  end if;
  v_fingerprint:=encode(extensions.digest(convert_to(v_payload::text,'UTF8'),'sha256'),'hex');

  select * into v_map from private.legacy_normalized_record_map m
  where m.business_id=p_business_id and m.legacy_collection=v_row.collection
    and m.legacy_id=v_legacy_id for update;
  if found then
   if v_map.import_status<>'mapped' then
    v_conflicts:=v_conflicts+1;
    update private.legacy_normalized_record_map set last_seen_at=now()
    where business_id=p_business_id and id=v_map.id;
    continue;
   end if;
   if v_map.source_fingerprint<>v_fingerprint then
    update private.legacy_normalized_record_map
    set import_status='conflict',note_code='source_changed',last_seen_at=now()
    where business_id=p_business_id and id=v_map.id;
    v_conflicts:=v_conflicts+1;
    continue;
   end if;
   if v_row.collection='categories' and not exists(
    select 1 from public.product_categories c where c.business_id=p_business_id and c.id=v_map.normalized_id
   ) then
    update private.legacy_normalized_record_map set import_status='orphaned',note_code='missing_reference',last_seen_at=now()
    where business_id=p_business_id and id=v_map.id;
    v_orphaned:=v_orphaned+1;
   elsif v_row.collection='services' and not exists(
    select 1 from public.services s where s.business_id=p_business_id and s.id=v_map.normalized_id
   ) then
    update private.legacy_normalized_record_map set import_status='orphaned',note_code='missing_reference',last_seen_at=now()
    where business_id=p_business_id and id=v_map.id;
    v_orphaned:=v_orphaned+1;
   elsif v_row.collection='warehouses' and not exists(
    select 1 from public.warehouses w where w.business_id=p_business_id and w.id=v_map.normalized_id
   ) then
    update private.legacy_normalized_record_map set import_status='orphaned',note_code='missing_reference',last_seen_at=now()
    where business_id=p_business_id and id=v_map.id;
    v_orphaned:=v_orphaned+1;
   else
    update private.legacy_normalized_record_map set last_seen_at=now()
    where business_id=p_business_id and id=v_map.id;
    v_unchanged:=v_unchanged+1;
   end if;
   continue;
  end if;

  if v_row.collection='categories' then
   select c.id into v_target_id from public.product_categories c
   where c.business_id=p_business_id and c.legacy_id=v_legacy_id;
   if v_target_id is not null then
    insert into private.legacy_normalized_record_map(
     business_id,legacy_collection,legacy_id,target_table,normalized_id,
     source_fingerprint,import_status,import_generation,note_code,created_by
    ) values(p_business_id,'categories',v_legacy_id,'product_categories',v_target_id,
     v_fingerprint,'conflict',p_import_generation,'target_conflict',v_user);
    v_conflicts:=v_conflicts+1; continue;
   end if;
   begin
    insert into public.product_categories(business_id,name,legacy_id)
    values(p_business_id,v_name,v_legacy_id) returning id into v_target_id;
   exception when unique_violation then
    v_conflicts:=v_conflicts+1; continue;
   when check_violation or string_data_right_truncation then
    v_invalid:=v_invalid+1; continue;
   end;
   insert into private.legacy_normalized_record_map(
    business_id,legacy_collection,legacy_id,target_table,normalized_id,
    source_fingerprint,import_status,import_generation,created_by
   ) values(p_business_id,'categories',v_legacy_id,'product_categories',v_target_id,
    v_fingerprint,'mapped',p_import_generation,v_user);
   v_imported_categories:=v_imported_categories+1;

  elsif v_row.collection='services' then
   select s.id into v_target_id from public.services s
   where s.business_id=p_business_id and s.legacy_id=v_legacy_id;
   if v_target_id is not null then
    insert into private.legacy_normalized_record_map(
     business_id,legacy_collection,legacy_id,target_table,normalized_id,
     source_fingerprint,import_status,import_generation,note_code,created_by
    ) values(p_business_id,'services',v_legacy_id,'services',v_target_id,
     v_fingerprint,'conflict',p_import_generation,'target_conflict',v_user);
    v_conflicts:=v_conflicts+1; continue;
   end if;
   begin
    insert into public.services(business_id,name,legacy_id,created_by)
    values(p_business_id,v_name,v_legacy_id,v_user) returning id into v_target_id;
   exception when unique_violation then
    v_conflicts:=v_conflicts+1; continue;
   when check_violation or string_data_right_truncation then
    v_invalid:=v_invalid+1; continue;
   end;
   insert into private.legacy_normalized_record_map(
    business_id,legacy_collection,legacy_id,target_table,normalized_id,
    source_fingerprint,import_status,import_generation,created_by
   ) values(p_business_id,'services',v_legacy_id,'services',v_target_id,
    v_fingerprint,'mapped',p_import_generation,v_user);
   v_imported_services:=v_imported_services+1;

  else
   select w.id into v_target_id from public.warehouses w
   where w.business_id=p_business_id and w.id::text=v_legacy_id;
   if v_target_id is not null then
    insert into private.legacy_normalized_record_map(
     business_id,legacy_collection,legacy_id,target_table,normalized_id,
     source_fingerprint,import_status,import_generation,note_code,created_by
    ) values(p_business_id,'warehouses',v_legacy_id,'warehouses',v_target_id,
     v_fingerprint,'conflict',p_import_generation,'target_conflict',v_user);
    v_conflicts:=v_conflicts+1; continue;
   end if;
   v_is_default:=not exists(
    select 1 from public.warehouses w where w.business_id=p_business_id and w.is_default and w.is_active
   );
   begin
    insert into public.warehouses(id,business_id,name,address,is_default)
    values(v_legacy_id::uuid,p_business_id,v_name,v_address,v_is_default)
    returning id into v_target_id;
   exception when unique_violation then
    v_conflicts:=v_conflicts+1; continue;
   when check_violation or string_data_right_truncation or invalid_text_representation then
    v_invalid:=v_invalid+1; continue;
   end;
   insert into private.legacy_normalized_record_map(
    business_id,legacy_collection,legacy_id,target_table,normalized_id,
    source_fingerprint,import_status,import_generation,created_by
   ) values(p_business_id,'warehouses',v_legacy_id,'warehouses',v_target_id,
    v_fingerprint,'mapped',p_import_generation,v_user);
   v_imported_warehouses:=v_imported_warehouses+1;
  end if;
 end loop;

 -- Link imported products to categories only by exact legacy category label;
 -- never infer by fuzzy name or overwrite a category already chosen by a user.
 update public.products p
 set category_id=c.id,version=p.version+1,updated_at=now()
 from private.business_state_records r
 join private.legacy_normalized_record_map pm
  on pm.business_id=r.business_id and pm.legacy_collection='prod'
  and pm.legacy_id=r.legacy_id and pm.import_status='mapped'
 join public.product_categories c
  on c.business_id=r.business_id and c.name=btrim(r.payload_public->>'category')
 where r.business_id=p_business_id and r.collection='prod' and r.deleted_at is null
  and p.business_id=p_business_id and p.id=pm.normalized_id
  and p.category_id is null and coalesce(r.payload_public->>'category','')<>'';
 get diagnostics v_categorized=row_count;

 select count(*) into v_unmapped_categories
 from private.business_state_records r
 join private.legacy_normalized_record_map pm
  on pm.business_id=r.business_id and pm.legacy_collection='prod'
  and pm.legacy_id=r.legacy_id and pm.import_status='mapped'
 where r.business_id=p_business_id and r.collection='prod' and r.deleted_at is null
  and coalesce(r.payload_public->>'category','')<>''
  and not exists(select 1 from public.product_categories c
    where c.business_id=p_business_id and c.name=btrim(r.payload_public->>'category'));

 return jsonb_build_object(
  'business_id',p_business_id,'generation',p_import_generation,
  'mode','catalog_and_warehouse_import',
  'imported_categories',v_imported_categories,'imported_services',v_imported_services,
  'imported_warehouses',v_imported_warehouses,'unchanged',v_unchanged,
  'conflicts',v_conflicts,'invalid',v_invalid,'orphaned_mappings',v_orphaned,
  'deleted_source_rows_skipped',v_deleted,'products_categorized',v_categorized,
  'products_with_unmapped_category',v_unmapped_categories,
  'stock_quantities_imported',false,'stock_movements_imported',false,
  'product_costs_imported',false,'financial_data_imported',false
 );
end;
$$;

revoke all on function public.import_legacy_catalog_and_warehouses(uuid,uuid) from public,anon;
grant execute on function public.import_legacy_catalog_and_warehouses(uuid,uuid) to authenticated;

commit;
