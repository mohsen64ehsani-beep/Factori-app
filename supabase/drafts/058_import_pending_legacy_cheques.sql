begin;
alter table private.legacy_normalized_record_map drop constraint if exists legacy_normalized_record_map_target_table_check;
alter table private.legacy_normalized_record_map add constraint legacy_normalized_record_map_target_table_check
check (target_table = any(array['contacts','products','product_categories','warehouses','services','documents','fiscal_periods','financial_transactions','cheques']));

create or replace function private.publish_cheque_to_legacy()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_contact_legacy text;v_payload jsonb;v_collection text;v_legacy_id text:=new.id::text;v_status text;
begin
 if pg_trigger_depth()>1 or coalesce(new.idempotency_key,'') like 'legacy-import-%' then return new; end if;
 select c.legacy_id into v_contact_legacy from public.contacts c where c.business_id=new.business_id and c.id=new.contact_id;
 v_status:=case when new.status='cleared' then 'received' when new.status in ('bounced','returned','cancelled') then 'returned' else 'pending' end;
 if new.cheque_direction='received' then
  v_collection:='pay';v_payload:=jsonb_build_object('id',v_legacy_id,'cid',coalesce(v_contact_legacy,new.contact_id::text),'kind','cheque','amt',new.amount,'dt',coalesce(new.issue_date,current_date)::text,'no',new.cheque_number,'sayad',coalesce(new.sayad_id,''),'cdt',new.due_date::text,'bank',coalesce(new.bank_name,''),'branch',coalesce(new.branch_name,''),'accountNo',coalesce(new.account_number,''),'accountHolder',coalesce(new.account_holder,''),'payee',coalesce(new.payee_name,''),'chequeType','صیادی','chequeImage','','tracking',new.cheque_number,'note',coalesce(new.note,''),'accountId','','status',v_status,'source','web');
 else
  v_collection:='supplierPayments';v_payload:=jsonb_build_object('id',v_legacy_id,'supplierId',coalesce(v_contact_legacy,new.contact_id::text),'amount',new.amount,'dt',coalesce(new.issue_date,current_date)::text,'method','cheque','accountId','','note',coalesce(new.note,''),'no',new.cheque_number,'sayad',coalesce(new.sayad_id,''),'bank',coalesce(new.bank_name,''),'cdt',new.due_date::text,'status',v_status);
 end if;
 perform private.write_legacy_master_record(new.business_id,v_collection,v_legacy_id,v_payload,false,new.created_by);
 return new;
end; $$;

create or replace function public.import_legacy_cash_financial_records(p_business_id uuid,p_import_generation uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v_user uuid:=auth.uid();v_row record;v_payload jsonb;v_collection text;v_legacy_id text;v_fingerprint text;v_map private.legacy_normalized_record_map%rowtype;
 v_contact_id uuid;v_account_id uuid;v_tx_id uuid;v_cheque_id uuid;v_amount numeric;v_date date;v_due_date date;v_contact_legacy text;v_account_legacy text;v_method text;v_reference text;v_description text;v_direction text;v_source_status text;v_target_table text;
 v_imported integer:=0;v_unchanged integer:=0;v_conflicts integer:=0;v_skipped integer:=0;v_invalid integer:=0;v_orphaned integer:=0;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required';end if;
 if p_import_generation is null then raise exception using errcode='22023',message='Import generation UUID is required';end if;
 if not private.has_business_permission(p_business_id,'business.settings.manage') or not private.has_business_permission(p_business_id,'payments.read') or not private.has_business_permission(p_business_id,'payments.write') then raise exception using errcode='42501',message='Financial import permissions are required';end if;
 perform 1 from public.businesses b where b.id=p_business_id and b.status='active' for update;
 if not found then raise exception using errcode='42501',message='Business is unavailable';end if;
 for v_row in select r.collection,r.legacy_id,r.payload_public,r.payload_private,r.deleted_at from private.business_state_records r where r.business_id=p_business_id and r.collection in ('pay','supplierPayments','expenses','otherincome') order by r.collection,r.legacy_id loop
  if v_row.deleted_at is not null then v_skipped:=v_skipped+1;continue;end if;
  v_collection:=v_row.collection;v_legacy_id:=v_row.legacy_id;v_payload:=private.merge_sensitive_json(v_row.payload_public,v_row.payload_private);
  if jsonb_typeof(v_payload)<>'object' or coalesce(v_payload->>'id','')<>v_legacy_id then v_invalid:=v_invalid+1;continue;end if;
  v_fingerprint:=encode(extensions.digest(convert_to(v_payload::text,'UTF8'),'sha256'),'hex');
  select * into v_map from private.legacy_normalized_record_map m where m.business_id=p_business_id and m.legacy_collection=v_collection and m.legacy_id=v_legacy_id for update;
  if found then
   if v_map.import_status<>'mapped' then v_conflicts:=v_conflicts+1;continue;end if;
   if v_map.source_fingerprint<>v_fingerprint then update private.legacy_normalized_record_map set import_status='conflict',note_code='source_changed',last_seen_at=now() where business_id=p_business_id and id=v_map.id;v_conflicts:=v_conflicts+1;continue;end if;
   if v_map.target_table='cheques' then
    if not exists(select 1 from public.cheques q where q.business_id=p_business_id and q.id=v_map.normalized_id) then update private.legacy_normalized_record_map set import_status='orphaned',note_code='missing_reference',last_seen_at=now() where business_id=p_business_id and id=v_map.id;v_orphaned:=v_orphaned+1;
    else update private.legacy_normalized_record_map set last_seen_at=now() where business_id=p_business_id and id=v_map.id;v_unchanged:=v_unchanged+1;end if;
   else
    if not exists(select 1 from public.financial_transactions t where t.business_id=p_business_id and t.id=v_map.normalized_id) then update private.legacy_normalized_record_map set import_status='orphaned',note_code='missing_reference',last_seen_at=now() where business_id=p_business_id and id=v_map.id;v_orphaned:=v_orphaned+1;
    else update private.legacy_normalized_record_map set last_seen_at=now() where business_id=p_business_id and id=v_map.id;v_unchanged:=v_unchanged+1;end if;
   end if;
   continue;
  end if;
  v_amount:=null;v_date:=null;v_due_date:=null;v_contact_id:=null;v_account_id:=null;v_reference:=null;v_description:=null;v_method:=null;v_direction:=null;v_target_table:='financial_transactions';
  if (v_collection='pay' and coalesce(v_payload->>'kind','')='cheque') or (v_collection='supplierPayments' and lower(coalesce(v_payload->>'method','')) in ('cheque','چک','check')) then
   v_direction:=case when v_collection='pay' then 'received' else 'issued' end;
   v_source_status:=lower(coalesce(v_payload->>'status','pending'));
   if v_source_status not in ('pending','در انتظار') then v_skipped:=v_skipped+1;continue;end if;
   v_contact_legacy:=case when v_direction='received' then nullif(v_payload->>'cid','') else nullif(v_payload->>'supplierId','') end;
   select c.id into v_contact_id from public.contacts c where c.business_id=p_business_id and c.legacy_id=v_contact_legacy and ((v_direction='received' and c.contact_type in ('customer','both')) or (v_direction='issued' and c.contact_type in ('supplier','both'))) limit 1;
   v_amount:=nullif(replace(coalesce(v_payload->>(case when v_direction='received' then 'amt' else 'amount' end),''),',',''),'')::numeric;
   if coalesce(v_payload->>'dt','') ~ '^\d{4}-\d{2}-\d{2}$' then v_date:=(v_payload->>'dt')::date;end if;
   if coalesce(v_payload->>'cdt','') ~ '^\d{4}-\d{2}-\d{2}$' then v_due_date:=(v_payload->>'cdt')::date;end if;
   if v_contact_id is null or v_amount is null or v_amount<=0 or trunc(v_amount)<>v_amount or v_due_date is null or coalesce(v_payload->>'no','')='' then v_skipped:=v_skipped+1;continue;end if;
   v_cheque_id:=public.create_cheque(p_business_id,v_direction,v_contact_id,v_payload->>'no',nullif(v_payload->>'sayad',''),nullif(v_payload->>'bank',''),nullif(v_payload->>'branch',''),nullif(v_payload->>'accountNo',''),nullif(v_payload->>'accountHolder',''),nullif(v_payload->>'drawerName',''),nullif(v_payload->>'payee',''),v_amount,v_date,v_due_date,coalesce(nullif(v_payload->>'note',''),'چک واردشده از سوابق اپ'),left('legacy-import-cheque:'||md5(v_collection||':'||v_legacy_id),120));
   v_target_table:='cheques';
   insert into private.legacy_normalized_record_map(business_id,legacy_collection,legacy_id,target_table,normalized_id,source_fingerprint,import_status,import_generation,created_by)
   values(p_business_id,v_collection,v_legacy_id,v_target_table,v_cheque_id,v_fingerprint,'mapped',p_import_generation,v_user);
   v_imported:=v_imported+1;continue;
  end if;
  if v_collection='pay' then
   if coalesce(v_payload->>'kind','')<>'cash' or coalesce(v_payload->>'status','received') not in ('received','paid','cleared','') then v_skipped:=v_skipped+1;continue;end if;
   v_contact_legacy:=nullif(v_payload->>'cid','');v_account_legacy:=nullif(v_payload->>'accountId','');
   v_amount:=nullif(replace(coalesce(v_payload->>'amt',''),',',''),'')::numeric;
   if coalesce(v_payload->>'dt','') ~ '^\d{4}-\d{2}-\d{2}$' then v_date:=(v_payload->>'dt')::date;end if;
   v_reference:=coalesce(nullif(v_payload->>'no',''),nullif(v_payload->>'tracking',''));v_description:=coalesce(nullif(v_payload->>'note',''),'دریافت نقدی واردشده از اپ');
   select c.id into v_contact_id from public.contacts c where c.business_id=p_business_id and c.legacy_id=v_contact_legacy and c.contact_type in ('customer','both') limit 1;
  elsif v_collection='supplierPayments' then
   v_method:=lower(coalesce(v_payload->>'method','cash'));if v_method in ('cheque','چک','check') then v_skipped:=v_skipped+1;continue;end if;
   v_contact_legacy:=nullif(v_payload->>'supplierId','');v_account_legacy:=nullif(v_payload->>'accountId','');
   v_amount:=nullif(replace(coalesce(v_payload->>'amount',''),',',''),'')::numeric;
   if coalesce(v_payload->>'dt','') ~ '^\d{4}-\d{2}-\d{2}$' then v_date:=(v_payload->>'dt')::date;end if;
   v_reference:=nullif(v_payload->>'reference','');v_description:=coalesce(nullif(v_payload->>'note',''),'پرداخت نقدی تأمین‌کننده واردشده از اپ');
   select c.id into v_contact_id from public.contacts c where c.business_id=p_business_id and c.legacy_id=v_contact_legacy and c.contact_type in ('supplier','both') limit 1;
  elsif v_collection='expenses' then
   v_account_legacy:=nullif(v_payload->>'accountId','');v_amount:=nullif(replace(coalesce(v_payload->>'amt',''),',',''),'')::numeric;
   if coalesce(v_payload->>'dt','') ~ '^\d{4}-\d{2}-\d{2}$' then v_date:=(v_payload->>'dt')::date;end if;
   v_description:=coalesce(nullif(v_payload->>'title',''),nullif(v_payload->>'note',''),'هزینه واردشده از اپ');
  else
   v_account_legacy:=nullif(v_payload->>'accountId','');v_amount:=nullif(replace(coalesce(v_payload->>'amount',''),',',''),'')::numeric;
   if coalesce(v_payload->>'dt','') ~ '^\d{4}-\d{2}-\d{2}$' then v_date:=(v_payload->>'dt')::date;end if;
   v_description:=coalesce(nullif(v_payload->>'title',''),nullif(v_payload->>'note',''),'درآمد متفرقه واردشده از اپ');
  end if;
  if v_amount is null or v_amount<=0 or trunc(v_amount)<>v_amount or v_date is null then v_invalid:=v_invalid+1;continue;end if;
  if v_collection in ('pay','supplierPayments') and v_contact_id is null then v_skipped:=v_skipped+1;continue;end if;
  if v_account_legacy is null then select a.id into v_account_id from public.financial_accounts a where a.business_id=p_business_id and a.is_active and a.is_default order by a.created_at limit 1;
  else select a.id into v_account_id from public.financial_accounts a where a.business_id=p_business_id and a.legacy_id=v_account_legacy and a.is_active limit 1;end if;
  if v_account_id is null then v_skipped:=v_skipped+1;continue;end if;
  if v_collection='pay' then v_tx_id:=public.post_customer_receipt(p_business_id,v_contact_id,v_account_id,v_amount,v_date,null,0,v_reference,v_description,'legacy-import-pay:'||v_legacy_id);
  elsif v_collection='supplierPayments' then v_tx_id:=public.post_simple_financial_transaction(p_business_id,'supplier_payment',v_contact_id,v_account_id,v_amount,v_date,v_reference,v_description,'legacy-import-supplier:'||v_legacy_id);
  elsif v_collection='expenses' then v_tx_id:=public.post_simple_financial_transaction(p_business_id,'expense_payment',null,v_account_id,v_amount,v_date,null,v_description,'legacy-import-expense:'||v_legacy_id);
  else v_tx_id:=public.post_simple_financial_transaction(p_business_id,'other_income',null,v_account_id,v_amount,v_date,null,v_description,'legacy-import-income:'||v_legacy_id);end if;
  insert into private.legacy_normalized_record_map(business_id,legacy_collection,legacy_id,target_table,normalized_id,source_fingerprint,import_status,import_generation,created_by)
  values(p_business_id,v_collection,v_legacy_id,v_target_table,v_tx_id,v_fingerprint,'mapped',p_import_generation,v_user);
  v_imported:=v_imported+1;
 end loop;
 return jsonb_build_object('business_id',p_business_id,'generation',p_import_generation,'mode','safe_cash_and_pending_cheque_import','imported',v_imported,'unchanged',v_unchanged,'conflicts',v_conflicts,'skipped',v_skipped,'invalid',v_invalid,'orphaned',v_orphaned,'deferred_collections',jsonb_build_array('cleared_or_returned_cheques','moneytransfers','creditorPayments','account_opening_balances','invoice_allocations'));
end; $$;
commit;