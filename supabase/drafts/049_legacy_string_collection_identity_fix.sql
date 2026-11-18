begin;
create or replace function private.write_legacy_master_record(p_business_id uuid,p_collection text,p_legacy_id text,p_payload jsonb,p_deleted boolean,p_actor uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_record_id uuid;v_version bigint;v_existing_payload jsonb;v_existing_private jsonb;v_deleted_at timestamptz;v_revision bigint;v_change_type text;v_public jsonb;v_private jsonb;v_cost_allowed boolean;v_identity_valid boolean;
begin
 if p_collection not in ('cust','suppliers','prod','inv','pay','creditorPayments','expenses','purchases','supplierPayments','returns','wastage','stockMoves','warehouseStocks','transfers','accounts','moneytransfers','opening','otherincome','serviceInv','duedates','fiscal','warehouses','services','categories','smsHistory')
  or p_legacy_id is null or length(btrim(p_legacy_id)) not between 1 and 200 then raise exception using errcode='22023',message='Invalid legacy master record identity'; end if;
 if p_collection in ('services','categories') then v_identity_valid:=jsonb_typeof(p_payload)='object' and coalesce(p_payload->>'value','')<>'' and p_legacy_id=('value:'||(p_payload->>'value'));
 else v_identity_valid:=jsonb_typeof(p_payload)='object' and coalesce(p_payload->>'id','')=p_legacy_id; end if;
 if not p_deleted and not coalesce(v_identity_valid,false) then raise exception using errcode='22023',message='Invalid legacy master record payload'; end if;
 v_public:=private.strip_sensitive_json(coalesce(p_payload,'{}'::jsonb));v_private:=private.extract_sensitive_json(coalesce(p_payload,'{}'::jsonb));
 v_cost_allowed:=coalesce(p_actor is not null and private.has_business_permission(p_business_id,'catalog.cost.read'),false);if not v_cost_allowed then v_private:='{}'::jsonb;end if;
 if p_deleted then
  update private.business_state_records set deleted_at=now(),version=version+1,updated_at=now(),updated_by=p_actor where business_id=p_business_id and collection=p_collection and legacy_id=p_legacy_id and deleted_at is null returning id,version into v_record_id,v_version;
  if not found then return;end if;v_change_type:='delete';
 else
  select id,version,payload_public,payload_private,deleted_at into v_record_id,v_version,v_existing_payload,v_existing_private,v_deleted_at from private.business_state_records where business_id=p_business_id and collection=p_collection and legacy_id=p_legacy_id for update;
  if found then
   if v_existing_payload=v_public and v_deleted_at is null and (not v_cost_allowed or v_existing_private=v_private) then return;end if;
   if not v_cost_allowed then v_private:=coalesce(v_existing_private,'{}'::jsonb);end if;
   update private.business_state_records set payload_public=v_public,payload_private=v_private,version=v_version+1,updated_at=now(),updated_by=p_actor,deleted_at=null where business_id=p_business_id and id=v_record_id returning version into v_version;
  else
   insert into private.business_state_records(business_id,collection,legacy_id,payload_public,payload_private,version,created_at,updated_at,updated_by) values(p_business_id,p_collection,p_legacy_id,v_public,v_private,1,now(),now(),p_actor) returning id,version into v_record_id,v_version;
  end if;v_change_type:='upsert';
 end if;
 insert into private.business_sync_counters(business_id,last_revision,updated_at) values(p_business_id,1,now()) on conflict(business_id) do update set last_revision=private.business_sync_counters.last_revision+1,updated_at=now() returning last_revision into v_revision;
 insert into public.record_revisions(business_id,record_type,record_id,revision,changed_by,change_type,change_payload) values(p_business_id,p_collection,v_record_id,v_revision,p_actor,v_change_type,jsonb_build_object('legacy_id',p_legacy_id,'version',v_version));
end; $$;
commit;