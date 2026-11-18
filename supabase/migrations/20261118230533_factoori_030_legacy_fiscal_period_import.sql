-- 030: Import legacy fiscal lock periods as closed normalized periods.
begin;

alter table private.legacy_normalized_record_map
 drop constraint if exists legacy_normalized_record_map_legacy_collection_check;
alter table private.legacy_normalized_record_map
 add constraint legacy_normalized_record_map_legacy_collection_check
 check(legacy_collection in ('cust','suppliers','prod','categories','warehouses','services','inv','serviceInv','fiscal'));

alter table private.legacy_normalized_record_map
 drop constraint if exists legacy_normalized_record_map_target_table_check;
alter table private.legacy_normalized_record_map
 add constraint legacy_normalized_record_map_target_table_check
 check(target_table in ('contacts','products','product_categories','warehouses','services','documents','fiscal_periods'));

create or replace function public.import_legacy_fiscal_periods(
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
 v_title text;
 v_from date;
 v_to date;
 v_fingerprint text;
 v_map private.legacy_normalized_record_map%rowtype;
 v_target_id uuid;
 v_imported integer:=0;
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
 if not private.has_business_permission(p_business_id,'business.settings.manage') then
  raise exception using errcode='42501',message='Business administration permission required';
 end if;
 perform 1 from public.businesses b where b.id=p_business_id and b.status='active' for update;
 if not found then
  raise exception using errcode='42501',message='Business is unavailable';
 end if;

 for v_row in
  select r.legacy_id,r.payload_public,r.deleted_at
  from private.business_state_records r
  where r.business_id=p_business_id and r.collection='fiscal'
  order by r.legacy_id
 loop
  if v_row.deleted_at is not null then
   v_deleted:=v_deleted+1; continue;
  end if;
  v_payload:=v_row.payload_public;
  v_legacy_id:=v_row.legacy_id;
  if jsonb_typeof(v_payload)<>'object' or coalesce(v_payload->>'id','')<>v_legacy_id
    or length(btrim(v_legacy_id)) not between 1 and 200 then
   v_invalid:=v_invalid+1; continue;
  end if;
  v_title:=nullif(btrim(v_payload->>'title'),'');
  if v_title is null or length(v_title)>100
    or coalesce(v_payload->>'from','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    or coalesce(v_payload->>'to','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
   v_invalid:=v_invalid+1; continue;
  end if;
  begin
   v_from:=(v_payload->>'from')::date;
   v_to:=(v_payload->>'to')::date;
  exception when invalid_datetime_format or datetime_field_overflow then
   v_invalid:=v_invalid+1; continue;
  end;
  if v_to<v_from then
   v_invalid:=v_invalid+1; continue;
  end if;
  v_fingerprint:=encode(extensions.digest(convert_to(v_payload::text,'UTF8'),'sha256'),'hex');

  select * into v_map from private.legacy_normalized_record_map m
  where m.business_id=p_business_id and m.legacy_collection='fiscal'
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
    v_conflicts:=v_conflicts+1; continue;
   end if;
   if not exists(select 1 from public.fiscal_periods fp
     where fp.business_id=p_business_id and fp.id=v_map.normalized_id) then
    update private.legacy_normalized_record_map
    set import_status='orphaned',note_code='missing_reference',last_seen_at=now()
    where business_id=p_business_id and id=v_map.id;
    v_orphaned:=v_orphaned+1;
   else
    update private.legacy_normalized_record_map set last_seen_at=now()
    where business_id=p_business_id and id=v_map.id;
    v_unchanged:=v_unchanged+1;
   end if;
   continue;
  end if;

  select fp.id into v_target_id from public.fiscal_periods fp
  where fp.business_id=p_business_id and fp.title=v_title
    and fp.date_from=v_from and fp.date_to=v_to
  limit 1;
  if v_target_id is not null then
   insert into private.legacy_normalized_record_map(
    business_id,legacy_collection,legacy_id,target_table,normalized_id,
    source_fingerprint,import_status,import_generation,note_code,created_by
   ) values(p_business_id,'fiscal',v_legacy_id,'fiscal_periods',v_target_id,
    v_fingerprint,'conflict',p_import_generation,'target_conflict',v_user);
   v_conflicts:=v_conflicts+1; continue;
  end if;
  if exists(select 1 from public.fiscal_periods fp
    where fp.business_id=p_business_id and daterange(fp.date_from,fp.date_to,'[]') && daterange(v_from,v_to,'[]')) then
   v_conflicts:=v_conflicts+1; continue;
  end if;

  insert into public.fiscal_periods(
   business_id,title,date_from,date_to,status,closed_at,closed_by
  ) values(
   p_business_id,v_title,v_from,v_to,'closed',now(),v_user
  ) returning id into v_target_id;
  insert into private.legacy_normalized_record_map(
   business_id,legacy_collection,legacy_id,target_table,normalized_id,
   source_fingerprint,import_status,import_generation,created_by
  ) values(p_business_id,'fiscal',v_legacy_id,'fiscal_periods',v_target_id,
   v_fingerprint,'mapped',p_import_generation,v_user);
  v_imported:=v_imported+1;
 end loop;

 return jsonb_build_object(
  'business_id',p_business_id,'generation',p_import_generation,
  'mode','closed_fiscal_period_import','imported_periods',v_imported,
  'unchanged',v_unchanged,'conflicts',v_conflicts,'invalid',v_invalid,
  'orphaned_mappings',v_orphaned,'deleted_source_rows_skipped',v_deleted,
  'all_imported_periods_closed',true
 );
end;
$$;

revoke all on function public.import_legacy_fiscal_periods(uuid,uuid) from public,anon;
grant execute on function public.import_legacy_fiscal_periods(uuid,uuid) to authenticated;

commit;
