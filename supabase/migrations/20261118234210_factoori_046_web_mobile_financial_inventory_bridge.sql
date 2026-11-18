begin;
create or replace function private.write_legacy_master_record(
 p_business_id uuid,p_collection text,p_legacy_id text,p_payload jsonb,p_deleted boolean,p_actor uuid
) returns void language plpgsql security definer set search_path='' as $$
declare
 v_record_id uuid;v_version bigint;v_existing_payload jsonb;v_existing_private jsonb;v_deleted_at timestamptz;
 v_revision bigint;v_change_type text;v_public jsonb;v_private jsonb;v_cost_allowed boolean;
begin
 if p_collection not in ('cust','suppliers','prod','inv','pay','creditorPayments','expenses','purchases','supplierPayments','returns','wastage','stockMoves','warehouseStocks','transfers','accounts','moneytransfers','opening','otherincome','serviceInv','duedates','fiscal','warehouses','services','categories','smsHistory')
  or p_legacy_id is null or length(btrim(p_legacy_id)) not between 1 and 200 then
  raise exception using errcode='22023',message='Invalid legacy master record identity';
 end if;
 if not p_deleted and (p_payload is null or jsonb_typeof(p_payload)<>'object' or coalesce(p_payload->>'id','')<>p_legacy_id) then
  raise exception using errcode='22023',message='Invalid legacy master record payload';
 end if;
 v_public:=private.strip_sensitive_json(coalesce(p_payload,'{}'::jsonb));
 v_private:=private.extract_sensitive_json(coalesce(p_payload,'{}'::jsonb));
 v_cost_allowed:=coalesce(p_actor is not null and private.has_business_permission(p_business_id,'catalog.cost.read'),false);
 if not v_cost_allowed then v_private:='{}'::jsonb; end if;
 if p_deleted then
  update private.business_state_records set deleted_at=now(),version=version+1,updated_at=now(),updated_by=p_actor
  where business_id=p_business_id and collection=p_collection and legacy_id=p_legacy_id and deleted_at is null
  returning id,version into v_record_id,v_version;
  if not found then return; end if;
  v_change_type:='delete';
 else
  select id,version,payload_public,payload_private,deleted_at into v_record_id,v_version,v_existing_payload,v_existing_private,v_deleted_at
  from private.business_state_records where business_id=p_business_id and collection=p_collection and legacy_id=p_legacy_id for update;
  if found then
   if v_existing_payload=v_public and v_deleted_at is null and (not v_cost_allowed or v_existing_private=v_private) then return; end if;
   if not v_cost_allowed then v_private:=coalesce(v_existing_private,'{}'::jsonb); end if;
   update private.business_state_records set payload_public=v_public,payload_private=v_private,version=v_version+1,updated_at=now(),updated_by=p_actor,deleted_at=null
   where business_id=p_business_id and id=v_record_id returning version into v_version;
  else
   insert into private.business_state_records(business_id,collection,legacy_id,payload_public,payload_private,version,created_at,updated_at,updated_by)
   values(p_business_id,p_collection,p_legacy_id,v_public,v_private,1,now(),now(),p_actor) returning id,version into v_record_id,v_version;
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

create or replace function private.publish_financial_transaction_to_legacy()
returns trigger language plpgsql security definer set search_path='' as $$
declare
 v_contact_legacy text;v_account_legacy text;v_payload jsonb;v_collection text;v_legacy_id text:=new.id::text;
begin
 if pg_trigger_depth()>1 then return new; end if;
 if new.idempotency_key like 'cheque-received-clear:%' or new.idempotency_key like 'cheque-issued-clear:%' then return new; end if;
 select c.legacy_id into v_contact_legacy from public.contacts c where c.business_id=new.business_id and c.id=new.contact_id;
 select a.legacy_id into v_account_legacy from public.financial_accounts a where a.business_id=new.business_id and a.id=new.account_id;
 v_account_legacy:=coalesce(v_account_legacy,new.account_id::text,'');
 if new.transaction_type='customer_receipt' then
  v_collection:='pay';
  v_payload:=jsonb_build_object('id',v_legacy_id,'cid',coalesce(v_contact_legacy,new.contact_id::text),
   'kind','cash','amt',new.amount,'dt',new.transaction_date::text,'no',coalesce(new.reference_number,''),
   'sayad','','cdt','','bank','','branch','','accountNo','','accountHolder','','payee','',
   'chequeType','','tracking',coalesce(new.reference_number,''),'note',coalesce(new.description,''),
   'accountId',v_account_legacy,'status','received','source','web',
   'invoiceId',coalesce(new.document_id::text,''));
 elsif new.transaction_type='supplier_payment' then
  v_collection:='supplierPayments';
  v_payload:=jsonb_build_object('id',v_legacy_id,'supplierId',coalesce(v_contact_legacy,new.contact_id::text),
   'amount',new.amount,'dt',new.transaction_date::text,'method','cash','accountId',v_account_legacy,
   'note',coalesce(new.description,''),'reference',coalesce(new.reference_number,''));
 elsif new.transaction_type='expense_payment' then
  v_collection:='expenses';
  v_payload:=jsonb_build_object('id',v_legacy_id,'title',coalesce(new.description,'هزینه ثبت‌شده از وب'),
   'amt',new.amount,'category','متفرقه','dt',new.transaction_date::text,'note',coalesce(new.description,''),
   'accountId',v_account_legacy);
 elsif new.transaction_type='other_income' then
  v_collection:='otherincome';
  v_payload:=jsonb_build_object('id',v_legacy_id,'title',coalesce(new.description,'درآمد متفرقه'),
   'amount',new.amount,'dt',new.transaction_date::text,'accountId',v_account_legacy,'note',coalesce(new.description,''));
 else
  return new;
 end if;
 perform private.write_legacy_master_record(new.business_id,v_collection,v_legacy_id,v_payload,false,new.created_by);
 return new;
end; $$;
drop trigger if exists financial_transactions_publish_legacy on public.financial_transactions;
create trigger financial_transactions_publish_legacy after insert on public.financial_transactions
for each row execute function private.publish_financial_transaction_to_legacy();

create or replace function private.publish_cheque_to_legacy()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_contact_legacy text;v_payload jsonb;v_collection text;v_legacy_id text:=new.id::text;v_status text;
begin
 if pg_trigger_depth()>1 then return new; end if;
 select c.legacy_id into v_contact_legacy from public.contacts c where c.business_id=new.business_id and c.id=new.contact_id;
 v_status:=case when new.status='cleared' then 'received' when new.status in ('bounced','returned','cancelled') then 'returned' else 'pending' end;
 if new.cheque_direction='received' then
  v_collection:='pay';
  v_payload:=jsonb_build_object('id',v_legacy_id,'cid',coalesce(v_contact_legacy,new.contact_id::text),
   'kind','cheque','amt',new.amount,'dt',coalesce(new.issue_date,current_date)::text,'no',new.cheque_number,
   'sayad',coalesce(new.sayad_id,''),'cdt',new.due_date::text,'bank',coalesce(new.bank_name,''),
   'branch',coalesce(new.branch_name,''),'accountNo',coalesce(new.account_number,''),
   'accountHolder',coalesce(new.account_holder,''),'payee',coalesce(new.payee_name,''),
   'chequeType','صیادی','chequeImage','','tracking',new.cheque_number,'note',coalesce(new.note,''),
   'accountId','','status',v_status,'source','web');
 else
  v_collection:='supplierPayments';
  v_payload:=jsonb_build_object('id',v_legacy_id,'supplierId',coalesce(v_contact_legacy,new.contact_id::text),
   'amount',new.amount,'dt',coalesce(new.issue_date,current_date)::text,'method','cheque','accountId','',
   'note',coalesce(new.note,''),'no',new.cheque_number,'sayad',coalesce(new.sayad_id,''),
   'bank',coalesce(new.bank_name,''),'cdt',new.due_date::text,'status',v_status);
 end if;
 perform private.write_legacy_master_record(new.business_id,v_collection,v_legacy_id,v_payload,false,new.created_by);
 return new;
end; $$;
drop trigger if exists cheques_publish_legacy on public.cheques;
create trigger cheques_publish_legacy after insert or update of status on public.cheques
for each row execute function private.publish_cheque_to_legacy();

create or replace function private.publish_stock_movement_to_legacy()
returns trigger language plpgsql security definer set search_path='' as $$
declare
 v_product_legacy text;v_warehouse_legacy text;v_product_name text;v_sale_price numeric;v_unit text;
 v_before numeric(20,4);v_after numeric(20,4);v_payload jsonb;v_product_payload jsonb;v_actor uuid;
begin
 if pg_trigger_depth()>1 then return new; end if;
 select p.legacy_id,p.name,p.sale_price,p.unit_name into v_product_legacy,v_product_name,v_sale_price,v_unit
 from public.products p where p.business_id=new.business_id and p.id=new.product_id;
 if v_product_legacy is null then v_product_legacy:=new.product_id::text; end if;
 select w.legacy_id into v_warehouse_legacy from public.warehouses w where w.business_id=new.business_id and w.id=new.warehouse_id;
 select coalesce(sum(sm.quantity_delta),0)-new.quantity_delta into v_before from public.stock_movements sm
 where sm.business_id=new.business_id and sm.product_id=new.product_id and sm.warehouse_id=new.warehouse_id;
 v_after:=v_before+new.quantity_delta;
 v_actor:=coalesce(new.created_by,auth.uid());
 v_payload:=jsonb_build_object('id',new.id::text,'pid',v_product_legacy,'dt',new.movement_date::date::text,
  'delta',new.quantity_delta,'before',v_before,'after',v_after,'reason',coalesce(new.note,new.movement_type),
  'warehouseId',coalesce(v_warehouse_legacy,new.warehouse_id::text));
 perform private.write_legacy_master_record(new.business_id,'stockMoves',new.id::text,v_payload,false,v_actor);
 select r.payload_public into v_product_payload from private.business_state_records r
 where r.business_id=new.business_id and r.collection='prod' and r.legacy_id=v_product_legacy and r.deleted_at is null;
 if v_product_payload is not null then
  v_product_payload:=jsonb_set(v_product_payload,'{qty}',to_jsonb((select coalesce(sum(sm.quantity_delta),0) from public.stock_movements sm where sm.business_id=new.business_id and sm.product_id=new.product_id)),true);
 else
  v_product_payload:=jsonb_build_object('id',v_product_legacy,'n',v_product_name,'sell',coalesce(v_sale_price,0),'unit_name',coalesce(v_unit,'عدد'),'qty',(select coalesce(sum(sm.quantity_delta),0) from public.stock_movements sm where sm.business_id=new.business_id and sm.product_id=new.product_id));
 end if;
 perform private.write_legacy_master_record(new.business_id,'prod',v_product_legacy,v_product_payload,false,v_actor);
 return new;
end; $$;
drop trigger if exists stock_movements_publish_legacy on public.stock_movements;
create trigger stock_movements_publish_legacy after insert on public.stock_movements
for each row execute function private.publish_stock_movement_to_legacy();

create or replace function public.web_import_legacy_supported_data(p_business_id uuid,p_import_generation uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_preview jsonb;v_reference jsonb;v_suppliers jsonb;v_catalog jsonb;v_fiscal jsonb;v_goods jsonb;v_services jsonb;v_reconcile jsonb;
begin
 if auth.uid() is null then raise exception using errcode='28000',message='Authentication required'; end if;
 if p_import_generation is null then raise exception using errcode='22023',message='Import generation UUID is required'; end if;
 if not private.has_business_permission(p_business_id,'business.settings.manage') then raise exception using errcode='42501',message='Business administration permission required'; end if;
 v_preview:=public.preview_legacy_normalization(p_business_id);
 if coalesce((v_preview->>'safe_to_import')::boolean,false) is not true then
  return jsonb_build_object('imported',false,'reason','preflight_not_safe','preflight',v_preview);
 end if;
 v_reference:=public.import_legacy_reference_data(p_business_id,p_import_generation);
 v_suppliers:=public.import_legacy_supplier_contacts(p_business_id,p_import_generation);
 v_catalog:=public.import_legacy_catalog_and_warehouses(p_business_id,p_import_generation);
 v_fiscal:=public.import_legacy_fiscal_periods(p_business_id,p_import_generation);
 v_goods:=public.import_legacy_goods_invoice_drafts(p_business_id,p_import_generation);
 v_services:=public.import_legacy_service_invoice_drafts(p_business_id,p_import_generation);
 v_reconcile:=public.reconcile_legacy_normalization(p_business_id);
 return jsonb_build_object('imported',true,'generation',p_import_generation,'preflight',v_preview,
  'reference_import',v_reference,'supplier_import',v_suppliers,'catalog_import',v_catalog,
  'fiscal_import',v_fiscal,'goods_invoice_import',v_goods,'service_invoice_import',v_services,
  'reconciliation',v_reconcile,'financial_records_deferred',true);
end; $$;
revoke all on function private.publish_financial_transaction_to_legacy() from public,anon,authenticated;
revoke all on function private.publish_cheque_to_legacy() from public,anon,authenticated;
revoke all on function private.publish_stock_movement_to_legacy() from public,anon,authenticated;
revoke all on function public.web_import_legacy_supported_data(uuid,uuid) from public,anon;
grant execute on function public.web_import_legacy_supported_data(uuid,uuid) to authenticated;
commit;