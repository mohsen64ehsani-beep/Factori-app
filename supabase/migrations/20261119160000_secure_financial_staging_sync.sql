create or replace function public.sync_stage_financial_records(
  p_business_id uuid,
  p_device_id uuid,
  p_operations jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_device public.sync_devices%rowtype;
  v_op jsonb;
  v_operation_id uuid;
  v_collection text;
  v_legacy_id text;
  v_base_version bigint;
  v_payload jsonb;
  v_payload_fingerprint text;
  v_request_fingerprint text;
  v_existing_fingerprint text;
  v_existing_result jsonb;
  v_record_id uuid;
  v_current_version bigint;
  v_new_version bigint;
  v_result jsonb;
  v_results jsonb := '[]'::jsonb;
  v_error text;
  v_state text;
begin
  if v_user_id is null then
    raise exception using errcode='28000', message='Authentication required';
  end if;

  select * into v_device
  from public.sync_devices d
  where d.business_id=p_business_id
    and d.id=p_device_id
    and d.user_id=v_user_id
    and d.status='active'
    and d.verified_at is not null
    and d.proof_version=1
  for update;

  if not found then
    raise exception using errcode='42501', message='Verified sync device proof required';
  end if;

  if not private.has_business_permission(p_business_id,'business.settings.manage')
     or not private.has_business_permission(p_business_id,'payments.read')
     or not private.has_business_permission(p_business_id,'payments.write')
     or not private.has_business_permission(p_business_id,'payments.create')
     or not private.has_business_permission(p_business_id,'expenses.create') then
    raise exception using errcode='42501', message='Financial staging permissions are required';
  end if;

  if p_operations is null or jsonb_typeof(p_operations)<>'array'
     or jsonb_array_length(p_operations)>100 then
    raise exception using errcode='22023', message='Invalid financial staging batch';
  end if;

  for v_op in select value from jsonb_array_elements(p_operations) as x(value)
  loop
    v_operation_id := null;
    v_request_fingerprint := null;
    v_collection := null;
    v_record_id := null;
    begin
      v_operation_id := nullif(v_op->>'operation_id','')::uuid;
      v_collection := v_op->>'collection';
      v_legacy_id := nullif(v_op->>'legacy_id','');
      v_base_version := nullif(v_op->>'base_version','')::bigint;
      v_payload := v_op->'payload';

      if v_operation_id is null
         or v_collection not in ('pay','supplierPayments','expenses','otherincome')
         or v_legacy_id is null or length(v_legacy_id) not between 1 and 200
         or coalesce(v_op->>'operation_type','')<>'upsert'
         or v_payload is null or jsonb_typeof(v_payload)<>'object'
         or octet_length(v_payload::text)>262144
         or coalesce(v_payload->>'id','')<>v_legacy_id then
        raise exception using errcode='22023', message='Invalid financial staging operation';
      end if;

      v_request_fingerprint := md5(jsonb_build_array(
        'upsert',v_collection,v_legacy_id,v_base_version,v_payload
      )::text);
      v_payload_fingerprint := encode(
        extensions.digest(convert_to(v_payload::text,'UTF8'),'sha256'),'hex'
      );

      perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
          p_business_id::text||':'||p_device_id::text||':'||v_operation_id::text,0
        )
      );

      select so.result_payload,so.request_fingerprint
        into v_existing_result,v_existing_fingerprint
      from public.sync_operations so
      where so.business_id=p_business_id
        and so.device_id=p_device_id
        and so.operation_id=v_operation_id;

      if found then
        if v_existing_fingerprint is distinct from v_request_fingerprint then
          raise exception using errcode='23505',
            message='Financial staging operation ID was reused with different data';
        end if;
        v_results := v_results || jsonb_build_array(coalesce(
          v_existing_result,
          jsonb_build_object('operation_id',v_operation_id,'status','duplicate')
        ));
        continue;
      end if;

      select r.id,r.version
        into v_record_id,v_current_version
      from private.business_state_records r
      where r.business_id=p_business_id
        and r.collection=v_collection
        and r.legacy_id=v_legacy_id
      for update;

      if found then
        if v_base_version is null or v_base_version<>v_current_version then
          v_result := jsonb_build_object(
            'operation_id',v_operation_id,'collection',v_collection,
            'legacy_id',v_legacy_id,'status','conflict',
            'current_version',v_current_version
          );
          insert into public.sync_operations(
            business_id,device_id,operation_id,request_fingerprint,
            operation_type,record_type,record_id,base_version,
            result_version,status,result_payload
          ) values (
            p_business_id,p_device_id,v_operation_id,v_request_fingerprint,
            'upsert',v_collection,v_record_id,v_base_version,
            v_current_version,'conflict',v_result
          );
          v_results := v_results || jsonb_build_array(v_result);
          continue;
        end if;
      elsif coalesce(v_base_version,0)<>0 then
        v_result := jsonb_build_object(
          'operation_id',v_operation_id,'collection',v_collection,
          'legacy_id',v_legacy_id,'status','conflict','current_version',0
        );
        insert into public.sync_operations(
          business_id,device_id,operation_id,request_fingerprint,
          operation_type,record_type,record_id,base_version,
          result_version,status,result_payload
        ) values (
          p_business_id,p_device_id,v_operation_id,v_request_fingerprint,
          'upsert',v_collection,null,v_base_version,
          0,'conflict',v_result
        );
        v_results := v_results || jsonb_build_array(v_result);
        continue;
      end if;

      if exists (
        select 1
        from private.legacy_normalized_record_map m
        where m.business_id=p_business_id
          and m.legacy_collection=v_collection
          and m.legacy_id=v_legacy_id
          and m.import_status='mapped'
          and m.source_fingerprint is distinct from v_payload_fingerprint
      ) then
        raise exception using errcode='55000',
          message='Imported financial source is immutable; use a validated financial correction';
      end if;

      perform private.write_legacy_master_record(
        p_business_id,v_collection,v_legacy_id,v_payload,false,v_user_id
      );

      select r.id,r.version
        into v_record_id,v_new_version
      from private.business_state_records r
      where r.business_id=p_business_id
        and r.collection=v_collection
        and r.legacy_id=v_legacy_id;

      v_result := jsonb_build_object(
        'operation_id',v_operation_id,'collection',v_collection,
        'legacy_id',v_legacy_id,'record_id',v_record_id,
        'status','applied','version',v_new_version
      );

      insert into public.sync_operations(
        business_id,device_id,operation_id,request_fingerprint,
        operation_type,record_type,record_id,base_version,
        result_version,status,result_payload
      ) values (
        p_business_id,p_device_id,v_operation_id,v_request_fingerprint,
        'upsert',v_collection,v_record_id,v_base_version,
        v_new_version,'applied',v_result
      );

      v_results := v_results || jsonb_build_array(v_result);
    exception when others then
      get stacked diagnostics v_error=message_text,v_state=returned_sqlstate;
      v_result := jsonb_build_object(
        'operation_id',v_operation_id,'collection',v_collection,
        'legacy_id',v_legacy_id,'status','rejected',
        'error_code',v_state,
        'message',case v_state
          when '42501' then 'operation_not_allowed'
          when '22023' then 'invalid_operation_data'
          when '23505' then 'duplicate_or_conflicting_operation'
          when '55000' then 'financial_source_already_imported'
          else 'operation_rejected'
        end
      );
      if v_operation_id is not null then
        insert into public.sync_operations(
          business_id,device_id,operation_id,request_fingerprint,
          operation_type,record_type,record_id,base_version,
          result_version,status,result_payload
        ) values (
          p_business_id,p_device_id,v_operation_id,
          v_request_fingerprint,coalesce(v_op->>'operation_type','upsert'),
          coalesce(v_collection,'financial'),v_record_id,v_base_version,
          null,'rejected',v_result
        ) on conflict (business_id,device_id,operation_id) do nothing;
      end if;
      v_results := v_results || jsonb_build_array(v_result);
    end;
  end loop;

  return v_results;
end;
$function$;

revoke all on function public.sync_stage_financial_records(uuid,uuid,jsonb) from public, anon;
grant execute on function public.sync_stage_financial_records(uuid,uuid,jsonb) to authenticated;
