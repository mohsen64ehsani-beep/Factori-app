-- 027: Import legacy service invoices as normalized drafts only.
-- Service costs and separate initial payments remain protected/deferred.
begin;

create or replace function public.import_legacy_service_invoice_drafts(
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
 v_fingerprint text;
 v_map private.legacy_normalized_record_map%rowtype;
 v_document_id uuid;
 v_contact_id uuid;
 v_service_id uuid;
 v_service_name text;
 v_document_number text;
 v_document_date date;
 v_discount numeric(20,0);
 v_quantity numeric(20,4);
 v_price numeric(20,0);
 v_subtotal numeric(30,0):=0;
 v_items jsonb;
 v_item jsonb;
 v_description text;
 v_item_count integer;
 v_valid boolean;
 v_idempotency_key text;
 v_imported integer:=0;
 v_unchanged integer:=0;
 v_conflicts integer:=0;
 v_invalid integer:=0;
 v_deleted integer:=0;
begin
 if v_user is null then
  raise exception using errcode='28000',message='Authentication required';
 end if;
 if p_import_generation is null then
  raise exception using errcode='22023',message='Import generation UUID is required';
 end if;
 if not private.has_business_permission(p_business_id,'business.settings.manage')
   or not private.has_business_permission(p_business_id,'sales.create')
   or not private.has_business_permission(p_business_id,'contacts.read')
   or not private.has_business_permission(p_business_id,'catalog.read') then
  raise exception using errcode='42501',message='Business administration and service invoice import permissions are required';
 end if;
 perform 1 from public.businesses b where b.id=p_business_id and b.status='active' for update;
 if not found then
  raise exception using errcode='42501',message='Business is unavailable';
 end if;

 for v_row in
  select r.legacy_id,r.payload_public,r.deleted_at
  from private.business_state_records r
  where r.business_id=p_business_id and r.collection='serviceInv'
  order by r.legacy_id
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
   v_invalid:=v_invalid+1; continue;
  end if;
  v_fingerprint:=encode(extensions.digest(convert_to(v_payload::text,'UTF8'),'sha256'),'hex');

  select * into v_map from private.legacy_normalized_record_map m
  where m.business_id=p_business_id and m.legacy_collection='serviceInv'
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
   if not exists(select 1 from public.documents d
     where d.business_id=p_business_id and d.id=v_map.normalized_id) then
    update private.legacy_normalized_record_map
    set import_status='orphaned',note_code='missing_reference',last_seen_at=now()
    where business_id=p_business_id and id=v_map.id;
    v_invalid:=v_invalid+1;
   else
    update private.legacy_normalized_record_map set last_seen_at=now()
    where business_id=p_business_id and id=v_map.id;
    v_unchanged:=v_unchanged+1;
   end if;
   continue;
  end if;

  if coalesce(v_payload->>'cid','')='' then
   v_invalid:=v_invalid+1; continue;
  end if;
  select m.normalized_id into v_contact_id
  from private.legacy_normalized_record_map m
  join public.contacts c on c.business_id=m.business_id and c.id=m.normalized_id
  where m.business_id=p_business_id and m.legacy_collection='cust'
    and m.legacy_id=v_payload->>'cid' and m.target_table='contacts'
    and m.import_status='mapped' and c.contact_type in ('customer','both') and c.is_active;
  if v_contact_id is null then
   v_invalid:=v_invalid+1; continue;
  end if;

  if coalesce(v_payload->>'dt','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
   v_invalid:=v_invalid+1; continue;
  end if;
  begin
   v_document_date:=(v_payload->>'dt')::date;
  exception when invalid_datetime_format or datetime_field_overflow then
   v_invalid:=v_invalid+1; continue;
  end;

  v_document_number:=nullif(btrim(v_payload->>'no'),'');
  if v_document_number is not null and length(v_document_number)>100 then
   v_invalid:=v_invalid+1; continue;
  end if;
  if coalesce(v_payload->>'discount','0') !~ '^[0-9]+([.][0-9]+)?$' then
   v_invalid:=v_invalid+1; continue;
  end if;
  begin
   v_discount:=coalesce(nullif(v_payload->>'discount','')::numeric,0)::numeric(20,0);
  exception when numeric_value_out_of_range or invalid_text_representation then
   v_invalid:=v_invalid+1; continue;
  end;
  if v_discount<0 or v_discount>999999999999999999 then
   v_invalid:=v_invalid+1; continue;
  end if;

  if jsonb_typeof(v_payload->'items')<>'array'
    or jsonb_array_length(v_payload->'items') not between 1 and 100 then
   v_invalid:=v_invalid+1; continue;
  end if;
  v_items:='[]'::jsonb;
  v_subtotal:=0;
  v_item_count:=0;
  v_valid:=true;
  for v_item in select value from jsonb_array_elements(v_payload->'items') loop
   v_item_count:=v_item_count+1;
   if jsonb_typeof(v_item)<>'object'
     or coalesce(v_item->>'desc','')=''
     or length(btrim(v_item->>'desc')) not between 1 and 500
     or coalesce(v_item->>'qty','') !~ '^[0-9]+([.][0-9]{1,4})?$'
     or coalesce(v_item->>'price','') !~ '^[0-9]+([.][0-9]+)?$' then
    v_valid:=false; exit;
   end if;
   begin
    v_quantity:=(v_item->>'qty')::numeric(20,4);
    v_price:=(v_item->>'price')::numeric(20,0);
   exception when numeric_value_out_of_range or invalid_text_representation then
    v_valid:=false; exit;
   end;
   if v_quantity<=0 or v_quantity>1000000000
     or v_price<0 or v_price>999999999999999999 then
    v_valid:=false; exit;
   end if;
   v_description:=btrim(v_item->>'desc');
   select m.normalized_id,s.name into v_service_id,v_service_name
   from private.legacy_normalized_record_map m
   join public.services s on s.business_id=m.business_id and s.id=m.normalized_id
   where m.business_id=p_business_id and m.legacy_collection='services'
    and m.legacy_id='value:'||v_description and m.target_table='services'
    and m.import_status='mapped' and s.is_active;
   if v_service_id is null then
    v_valid:=false; exit;
   end if;
   v_items:=v_items||jsonb_build_array(jsonb_build_object(
    'item_type','service','service_id',v_service_id,'description',v_description,
    'quantity',v_quantity,'unit_name','خدمت','unit_price',v_price,
    'discount_amount',0,'tax_rate',0
   ));
   v_subtotal:=v_subtotal+round(v_quantity*v_price);
  end loop;
  if not v_valid or v_item_count<1 or v_item_count>100 or v_discount>v_subtotal then
   v_invalid:=v_invalid+1; continue;
  end if;

  v_idempotency_key:='legacy-service-inv:'||md5(v_legacy_id);
  if v_document_number is not null and exists(
   select 1 from public.documents d
   where d.business_id=p_business_id and d.document_type='service_sale'
    and d.document_number=v_document_number and d.contact_id=v_contact_id
    and d.document_date=v_document_date
  ) then
   v_conflicts:=v_conflicts+1; continue;
  end if;

  v_document_id:=public.create_document_draft(
   p_business_id,'service_sale',v_contact_id,null,null,
   v_document_date,null,null,v_discount,null,v_items,v_idempotency_key
  );
  update public.documents
  set document_number=v_document_number
  where business_id=p_business_id and id=v_document_id;

  insert into private.legacy_normalized_record_map(
   business_id,legacy_collection,legacy_id,target_table,normalized_id,
   source_fingerprint,import_status,import_generation,created_by
  ) values(
   p_business_id,'serviceInv',v_legacy_id,'documents',v_document_id,
   v_fingerprint,'mapped',p_import_generation,v_user
  );
  v_imported:=v_imported+1;
 end loop;

 return jsonb_build_object(
  'business_id',p_business_id,'generation',p_import_generation,
  'mode','draft_service_invoice_import','imported_drafts',v_imported,
  'unchanged',v_unchanged,'conflicts',v_conflicts,'invalid',v_invalid,
  'deleted_source_rows_skipped',v_deleted,
  'documents_posted',false,'financial_transactions_created',false,
  'journal_entries_created',false,'initial_payments_imported',false,
  'legacy_service_costs_imported',false
 );
end;
$$;

revoke all on function public.import_legacy_service_invoice_drafts(uuid,uuid) from public,anon;
grant execute on function public.import_legacy_service_invoice_drafts(uuid,uuid) to authenticated;

commit;
