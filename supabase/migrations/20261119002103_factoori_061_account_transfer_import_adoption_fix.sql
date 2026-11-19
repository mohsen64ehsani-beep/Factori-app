begin;
alter table private.legacy_normalized_record_map drop constraint if exists legacy_normalized_record_map_legacy_collection_check;
alter table private.legacy_normalized_record_map add constraint legacy_normalized_record_map_legacy_collection_check
check (legacy_collection = any(array['cust','suppliers','prod','categories','warehouses','services','inv','serviceInv','fiscal','pay','supplierPayments','expenses','otherincome','purchases','moneytransfers']));
alter table private.legacy_normalized_record_map drop constraint if exists legacy_normalized_record_map_target_table_check;
alter table private.legacy_normalized_record_map add constraint legacy_normalized_record_map_target_table_check
check (target_table = any(array['contacts','products','product_categories','warehouses','services','documents','fiscal_periods','financial_transactions','cheques','account_transfers']));

create or replace function private.publish_account_transfer_to_legacy()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_from_legacy text;v_to_legacy text;v_payload jsonb;
begin
 if pg_trigger_depth()>1 or coalesce(new.idempotency_key,'') like 'legacy-import-%' then return new;end if;
 select legacy_id into v_from_legacy from public.financial_accounts where business_id=new.business_id and id=new.from_account_id;
 select legacy_id into v_to_legacy from public.financial_accounts where business_id=new.business_id and id=new.to_account_id;
 v_payload:=jsonb_build_object('id',new.id::text,'dt',new.transfer_date::text,'fromAccount',coalesce(v_from_legacy,new.from_account_id::text),
  'toAccount',coalesce(v_to_legacy,new.to_account_id::text),'amount',new.amount,'note',coalesce(new.note,''));
 perform private.write_legacy_master_record(new.business_id,'moneytransfers',new.id::text,v_payload,false,new.created_by);
 return new;
end; $$;
drop trigger if exists account_transfers_publish_legacy on public.account_transfers;
create trigger account_transfers_publish_legacy after insert on public.account_transfers for each row execute function private.publish_account_transfer_to_legacy();

create or replace function public.import_legacy_account_transfers(p_business_id uuid,p_import_generation uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid();v_row record;v_payload jsonb;v_legacy_id text;v_fingerprint text;v_map private.legacy_normalized_record_map%rowtype;
 v_from_account uuid;v_to_account uuid;v_transfer_id uuid;v_amount numeric;v_date date;v_note text;
 v_imported integer:=0;v_unchanged integer:=0;v_conflicts integer:=0;v_skipped integer:=0;v_invalid integer:=0;v_orphaned integer:=0;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required';end if;
 if p_import_generation is null then raise exception using errcode='22023',message='Import generation UUID is required';end if;
 if not private.has_business_permission(p_business_id,'business.settings.manage') or not private.has_business_permission(p_business_id,'payments.read') or not private.has_business_permission(p_business_id,'payments.write') then raise exception using errcode='42501',message='Account transfer import permissions are required';end if;
 perform 1 from public.businesses b where b.id=p_business_id and b.status='active' for update;
 if not found then raise exception using errcode='42501',message='Business is unavailable';end if;
 for v_row in select r.legacy_id,r.payload_public,r.payload_private,r.deleted_at from private.business_state_records r where r.business_id=p_business_id and r.collection='moneytransfers' order by r.legacy_id loop
  if v_row.deleted_at is not null then v_skipped:=v_skipped+1;continue;end if;
  v_legacy_id:=v_row.legacy_id;v_payload:=private.merge_sensitive_json(v_row.payload_public,v_row.payload_private);
  if jsonb_typeof(v_payload)<>'object' or coalesce(v_payload->>'id','')<>v_legacy_id then v_invalid:=v_invalid+1;continue;end if;
  v_fingerprint:=encode(extensions.digest(convert_to(v_payload::text,'UTF8'),'sha256'),'hex');
  select * into v_map from private.legacy_normalized_record_map m where m.business_id=p_business_id and m.legacy_collection='moneytransfers' and m.legacy_id=v_legacy_id for update;
  if found then
   if v_map.import_status<>'mapped' then v_conflicts:=v_conflicts+1;continue;end if;
   if v_map.source_fingerprint<>v_fingerprint then update private.legacy_normalized_record_map set import_status='conflict',note_code='source_changed',last_seen_at=now() where business_id=p_business_id and id=v_map.id;v_conflicts:=v_conflicts+1;continue;end if;
   if not exists(select 1 from public.account_transfers t where t.business_id=p_business_id and t.id=v_map.normalized_id) then update private.legacy_normalized_record_map set import_status='orphaned',note_code='missing_reference',last_seen_at=now() where business_id=p_business_id and id=v_map.id;v_orphaned:=v_orphaned+1;
   else update private.legacy_normalized_record_map set last_seen_at=now() where business_id=p_business_id and id=v_map.id;v_unchanged:=v_unchanged+1;end if;
   continue;
  end if;
  begin
   v_transfer_id:=v_legacy_id::uuid;
  exception when invalid_text_representation then
   v_transfer_id:=null;
  end;
  if v_transfer_id is not null and exists(select 1 from public.account_transfers t where t.business_id=p_business_id and t.id=v_transfer_id) then
   insert into private.legacy_normalized_record_map(business_id,legacy_collection,legacy_id,target_table,normalized_id,source_fingerprint,import_status,import_generation,created_by)
   values(p_business_id,'moneytransfers',v_legacy_id,'account_transfers',v_transfer_id,v_fingerprint,'mapped',p_import_generation,v_user);
   v_unchanged:=v_unchanged+1;continue;
  end if;
  v_from_account:=null;v_to_account:=null;v_amount:=null;v_date:=null;
  select id into v_from_account from public.financial_accounts where business_id=p_business_id and legacy_id=nullif(v_payload->>'fromAccount','') and is_active limit 1;
  select id into v_to_account from public.financial_accounts where business_id=p_business_id and legacy_id=nullif(v_payload->>'toAccount','') and is_active limit 1;
  v_amount:=nullif(replace(coalesce(v_payload->>'amount',''),',',''),'')::numeric;
  if coalesce(v_payload->>'dt','') ~ '^\d{4}-\d{2}-\d{2}$' then v_date:=(v_payload->>'dt')::date;end if;
  if v_from_account is null or v_to_account is null or v_from_account=v_to_account then v_skipped:=v_skipped+1;continue;end if;
  if v_amount is null or v_amount<=0 or trunc(v_amount)<>v_amount or v_date is null then v_invalid:=v_invalid+1;continue;end if;
  v_note:=coalesce(nullif(v_payload->>'note',''),'انتقال وجه واردشده از اپ');
  begin
   v_transfer_id:=public.post_account_transfer(p_business_id,v_from_account,v_to_account,v_amount,v_date,v_note,left('legacy-import-transfer:'||md5(v_legacy_id),120),null);
  exception when check_violation or invalid_parameter_value or object_not_in_prerequisite_state then
   v_skipped:=v_skipped+1;continue;
  end;
  insert into private.legacy_normalized_record_map(business_id,legacy_collection,legacy_id,target_table,normalized_id,source_fingerprint,import_status,import_generation,created_by)
  values(p_business_id,'moneytransfers',v_legacy_id,'account_transfers',v_transfer_id,v_fingerprint,'mapped',p_import_generation,v_user);
  v_imported:=v_imported+1;
 end loop;
 return jsonb_build_object('business_id',p_business_id,'generation',p_import_generation,'mode','legacy_account_transfer_import','imported',v_imported,'unchanged',v_unchanged,'conflicts',v_conflicts,'skipped',v_skipped,'invalid',v_invalid,'orphaned',v_orphaned);
end; $$;

create or replace function public.web_import_legacy_supported_data(p_business_id uuid,p_import_generation uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_preview jsonb;v_reference jsonb;v_suppliers jsonb;v_catalog jsonb;v_fiscal jsonb;v_goods jsonb;v_services jsonb;v_purchases jsonb;v_financial jsonb;v_transfers jsonb;v_reconcile jsonb;
begin
 if auth.uid() is null then raise exception using errcode='28000',message='Authentication required';end if;
 if p_import_generation is null then raise exception using errcode='22023',message='Import generation UUID is required';end if;
 if not private.has_business_permission(p_business_id,'business.settings.manage') then raise exception using errcode='42501',message='Business administration permission required';end if;
 v_preview:=public.preview_legacy_normalization(p_business_id);
 if coalesce((v_preview->>'safe_to_import')::boolean,false) is not true then return jsonb_build_object('imported',false,'reason','preflight_not_safe','preflight',v_preview);end if;
 v_reference:=public.import_legacy_reference_data(p_business_id,p_import_generation);
 v_suppliers:=public.import_legacy_supplier_contacts(p_business_id,p_import_generation);
 v_catalog:=public.import_legacy_catalog_and_warehouses(p_business_id,p_import_generation);
 v_fiscal:=public.import_legacy_fiscal_periods(p_business_id,p_import_generation);
 v_goods:=public.import_legacy_goods_invoice_drafts(p_business_id,p_import_generation);
 v_services:=public.import_legacy_service_invoice_drafts(p_business_id,p_import_generation);
 v_purchases:=public.import_legacy_purchase_drafts(p_business_id,p_import_generation);
 v_financial:=public.import_legacy_cash_financial_records(p_business_id,p_import_generation);
 v_transfers:=public.import_legacy_account_transfers(p_business_id,p_import_generation);
 v_reconcile:=public.reconcile_legacy_normalization(p_business_id);
 return jsonb_build_object('imported',true,'generation',p_import_generation,'preflight',v_preview,'reference_import',v_reference,'supplier_import',v_suppliers,'catalog_import',v_catalog,'fiscal_import',v_fiscal,'goods_invoice_import',v_goods,'service_invoice_import',v_services,'purchase_import',v_purchases,'financial_import',v_financial,'transfer_import',v_transfers,'reconciliation',v_reconcile,'financial_records_deferred',coalesce((v_financial->>'skipped')::integer,0)>0 or coalesce((v_transfers->>'skipped')::integer,0)>0);
end; $$;
revoke all on function private.publish_account_transfer_to_legacy() from public,anon,authenticated;
revoke all on function public.import_legacy_account_transfers(uuid,uuid) from public,anon;
grant execute on function public.import_legacy_account_transfers(uuid,uuid) to authenticated;
revoke all on function public.web_import_legacy_supported_data(uuid,uuid) from public,anon;
grant execute on function public.web_import_legacy_supported_data(uuid,uuid) to authenticated;
commit;