-- Offline-first compatibility sync for the existing db:v2 collections.
-- Draft only: this migration is not applied to the production Supabase project.

begin;

create table private.business_state_records (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  collection text not null,
  legacy_id text not null,
  payload_public jsonb not null default '{}'::jsonb,
  payload_private jsonb not null default '{}'::jsonb,
  version bigint not null default 1 check (version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id),
  deleted_at timestamptz,
  unique (business_id,collection,legacy_id),
  unique (business_id,id),
  check (jsonb_typeof(payload_public)='object')
);

create table private.business_sync_counters (
  business_id uuid primary key references public.businesses(id) on delete restrict,
  last_revision bigint not null default 0 check (last_revision >= 0),
  updated_at timestamptz not null default now()
);

alter table private.business_state_records enable row level security;
alter table private.business_sync_counters enable row level security;
revoke all on table private.business_state_records,private.business_sync_counters from public,anon,authenticated;

create index business_state_records_sync_idx
  on private.business_state_records(business_id,collection,updated_at);
create index business_state_records_live_idx
  on private.business_state_records(business_id,collection,legacy_id)
  where deleted_at is null;
create index if not exists record_revisions_business_cursor_idx
  on public.record_revisions(business_id,revision);
create index if not exists sync_operations_record_idx
  on public.sync_operations(business_id,record_type,record_id,created_at desc);

create or replace function private.strip_sensitive_json(p_value jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $fn$
declare
  v_result jsonb;
begin
  if p_value is null then return null; end if;
  case jsonb_typeof(p_value)
    when 'object' then
      select coalesce(jsonb_object_agg(e.key,private.strip_sensitive_json(e.value)),'{}'::jsonb)
        into v_result
      from jsonb_each(p_value) e
      where e.key not in (
        'buy','b','cost','costTotal','cost_total','unitCostAtReturn','unit_cost_at_return',
        'unit_cost','unitCost','buyPrice','purchasePrice','costPrice','cost_price','total_cost',
        'last_purchase_cost','average_cost','averageCost','avgCost','average_unit_cost','inventory_value',
        'profit','profitAmount','margin','marginAmount','purchase_cost','cost_snapshot','unit_cost_snapshot'
      );
      return v_result;
    when 'array' then
      select coalesce(jsonb_agg(private.strip_sensitive_json(e.value) order by e.ordinality),'[]'::jsonb)
        into v_result
      from jsonb_array_elements(p_value) with ordinality e(value,ordinality);
      return v_result;
    else
      return p_value;
  end case;
end;
$fn$;

create or replace function private.extract_sensitive_json(p_value jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $fn$
declare
  v_result jsonb;
begin
  if p_value is null then return null; end if;
  case jsonb_typeof(p_value)
    when 'object' then
      select coalesce(jsonb_object_agg(e.key,
        case when e.key in (
          'buy','b','cost','costTotal','cost_total','unitCostAtReturn','unit_cost_at_return',
        'unit_cost','unitCost','buyPrice','purchasePrice','costPrice','cost_price','total_cost',
          'last_purchase_cost','average_cost','averageCost','avgCost','average_unit_cost','inventory_value',
          'profit','profitAmount','margin','marginAmount','purchase_cost','cost_snapshot','unit_cost_snapshot'
        ) then e.value else private.extract_sensitive_json(e.value) end
      ),'{}'::jsonb)
        into v_result
      from jsonb_each(p_value) e
      where e.key in (
        'buy','b','cost','costTotal','cost_total','unitCostAtReturn','unit_cost_at_return',
        'unit_cost','unitCost','buyPrice','purchasePrice','costPrice','cost_price','total_cost',
        'last_purchase_cost','average_cost','averageCost','avgCost','average_unit_cost','inventory_value',
        'profit','profitAmount','margin','marginAmount','purchase_cost','cost_snapshot','unit_cost_snapshot'
      )
      or private.extract_sensitive_json(e.value) not in ('{}'::jsonb,'[]'::jsonb,'null'::jsonb);
      return v_result;
    when 'array' then
      select coalesce(jsonb_agg(private.extract_sensitive_json(e.value) order by e.ordinality),'[]'::jsonb)
        into v_result
      from jsonb_array_elements(p_value) with ordinality e(value,ordinality);
      return v_result;
    else
      return 'null'::jsonb;
  end case;
end;
$fn$;

create or replace function private.merge_sensitive_json(p_public jsonb,p_private jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $fn$
declare
  v_result jsonb;
  v_len integer;
begin
  if p_private is null or p_private='null'::jsonb then return p_public; end if;
  if p_public is null or p_public='null'::jsonb then return p_private; end if;
  if jsonb_typeof(p_public)='object' and jsonb_typeof(p_private)='object' then
    select coalesce(jsonb_object_agg(k,private.merge_sensitive_json(p_public->k,p_private->k)),'{}'::jsonb)
      into v_result
    from (
      select k from jsonb_object_keys(p_public) as a(k)
      union
      select k from jsonb_object_keys(p_private) as b(k)
    ) keys;
    return v_result;
  elsif jsonb_typeof(p_public)='array' and jsonb_typeof(p_private)='array' then
    v_len:=greatest(jsonb_array_length(p_public),jsonb_array_length(p_private));
    if v_len=0 then return '[]'::jsonb; end if;
    select coalesce(jsonb_agg(private.merge_sensitive_json(p_public->g.i,p_private->g.i) order by g.i),'[]'::jsonb)
      into v_result
    from generate_series(0,v_len-1) as g(i);
    return v_result;
  end if;
  return p_private;
end;
$fn$;

create or replace function private.can_sync_collection(
  p_business_id uuid,
  p_collection text,
  p_operation text
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  v_permission text;
begin
  if p_operation='read' then
    v_permission:=case p_collection
      when 'cust' then 'contacts.read'
      when 'suppliers' then 'contacts.read'
      when 'debt' then 'contacts.read'
      when 'duedates' then 'contacts.read'
      when 'prod' then 'catalog.read'
      when 'services' then 'catalog.read'
      when 'categories' then 'catalog.read'
      when 'inv' then 'sales.read'
      when 'serviceInv' then 'sales.read'
      when 'returns' then 'sales.read'
      when 'pay' then 'payments.read'
      when 'creditors' then 'purchases.read'
      when 'purchases' then 'purchases.read'
      when 'supplierPayments' then 'payments.read'
      when 'creditorPayments' then 'payments.read'
      when 'expenses' then 'expenses.read'
      when 'otherincome' then 'expenses.read'
      when 'wastage' then 'expenses.read'
      when 'warehouses' then 'inventory.read'
      when 'stockMoves' then 'inventory.read'
      when 'warehouseStocks' then 'inventory.read'
      when 'transfers' then 'inventory.read'
      when 'accounts' then 'payments.read'
      when 'moneytransfers' then 'payments.read'
      when 'opening' then 'payments.read'
      when 'bankAccounts' then 'invoice.settings.read'
      when 'fiscal' then 'settings.read'
      when 'advancedSettings' then 'settings.read'
      when 'smsHistory' then 'settings.manage'
      else null end;
  elsif p_operation in ('write','delete') then
    v_permission:=case p_collection
      when 'cust' then 'contacts.write'
      when 'suppliers' then 'contacts.write'
      when 'debt' then null
      when 'duedates' then 'contacts.write'
      when 'prod' then 'catalog.write'
      when 'services' then 'catalog.write'
      when 'categories' then 'catalog.write'
      when 'inv' then 'sales.create'
      when 'serviceInv' then 'sales.create'
      when 'returns' then null
      when 'pay' then null
      when 'creditors' then null
      when 'purchases' then null
      when 'supplierPayments' then null
      when 'creditorPayments' then null
      when 'expenses' then null
      when 'otherincome' then null
      when 'wastage' then null
      when 'warehouses' then 'inventory.adjust'
      when 'stockMoves' then null
      when 'warehouseStocks' then null
      when 'transfers' then null
      when 'accounts' then null
      when 'moneytransfers' then null
      when 'opening' then null
      when 'bankAccounts' then 'settings.manage'
      when 'fiscal' then 'settings.manage'
      when 'advancedSettings' then 'settings.manage'
      when 'smsHistory' then 'settings.manage'
      else null end;
  else
    return false;
  end if;
  if v_permission is null then return false; end if;
  return (select private.has_business_permission(p_business_id,v_permission));
end;
$fn$;

create or replace function private.register_sync_device(
  p_business_id uuid,
  p_device_name text,
  p_platform text,
  p_device_public_key jsonb default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_user_id uuid:=auth.uid();
  v_device_id uuid;
  v_permission_version bigint;
begin
  if v_user_id is null or not (select private.is_business_member(p_business_id)) then
    raise exception 'not_authorized' using errcode='42501';
  end if;
  if p_platform not in ('android','web','ios','other') then
    raise exception 'invalid_device_platform' using errcode='22023';
  end if;
  select permission_version into v_permission_version from public.business_members
  where business_id=p_business_id and user_id=v_user_id and status='active';
  insert into public.sync_devices(
    business_id,user_id,permission_version,device_name,platform,device_public_key,status,last_seen_at
  ) values (
    p_business_id,v_user_id,v_permission_version,left(coalesce(p_device_name,'Factoori device'),120),
    p_platform,p_device_public_key,'active',now()
  ) returning id into v_device_id;
  insert into public.sync_cursors(business_id,device_id,last_revision,last_synced_at)
  values (p_business_id,v_device_id,0,null);
  return v_device_id;
end;
$fn$;

create or replace function private.sync_push(
  p_business_id uuid,
  p_device_id uuid,
  p_operations jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_user_id uuid:=auth.uid();
  v_device public.sync_devices%rowtype;
  v_member_permission_version bigint;
  v_op jsonb;
  v_operation_id uuid;
  v_collection text;
  v_operation_type text;
  v_legacy_id text;
  v_base_version bigint;
  v_payload jsonb;
  v_payload_public jsonb;
  v_payload_private jsonb;
  v_existing private.business_state_records%rowtype;
  v_record_id uuid;
  v_current_version bigint;
  v_new_version bigint;
  v_revision bigint;
  v_result jsonb;
  v_results jsonb:='[]'::jsonb;
  v_cost_allowed boolean;
  v_timezone text;
  v_local_date date;
  v_item_count integer;
  v_error text;
  v_state text;
  v_request_fingerprint text;
  v_existing_fingerprint text;
begin
  if v_user_id is null or not (select private.is_business_member(p_business_id)) then
    raise exception 'not_authorized' using errcode='42501';
  end if;
  if p_operations is null or jsonb_typeof(p_operations)<>'array'
     or jsonb_array_length(p_operations)>100 then
    raise exception 'invalid_sync_batch' using errcode='22023';
  end if;
  select * into v_device
  from public.sync_devices d
  where d.business_id=p_business_id and d.id=p_device_id
    and d.user_id=v_user_id and d.status='active'
  for update;
  if not found then raise exception 'sync_device_not_found' using errcode='42501'; end if;
  select permission_version into v_member_permission_version from public.business_members
  where business_id=p_business_id and user_id=v_user_id and status='active';
  if v_device.permission_version<>v_member_permission_version then
    raise exception 'sync_permissions_changed' using errcode='42501';
  end if;
  update public.sync_devices set last_seen_at=now()
  where business_id=p_business_id and id=p_device_id;
  v_cost_allowed:=(select private.has_business_permission(p_business_id,'catalog.cost.read'));

  for v_op in select value from jsonb_array_elements(p_operations) as x(value)
  loop
    v_operation_id:=null;
    v_request_fingerprint:=null;
    v_existing_fingerprint:=null;
    v_collection:=null;
    v_record_id:=null;
    begin
      v_operation_id:=nullif(v_op->>'operation_id','')::uuid;
      v_collection:=v_op->>'collection';
      v_operation_type:=v_op->>'operation_type';
      v_legacy_id:=nullif(v_op->>'legacy_id','');
      v_base_version:=nullif(v_op->>'base_version','')::bigint;
      v_payload:=v_op->'payload';

      if v_operation_id is null or v_collection is null or v_legacy_id is null
         or length(v_legacy_id) not between 1 and 200
         or v_operation_type is null or v_operation_type not in ('upsert','delete') then
        raise exception 'invalid_sync_operation' using errcode='22023';
      end if;
      if v_operation_type='upsert' and (
        v_payload is null or jsonb_typeof(v_payload)<>'object'
        or octet_length(v_payload::text)>262144
      ) then
        raise exception 'invalid_sync_payload' using errcode='22023';
      end if;
      v_request_fingerprint:=md5(jsonb_build_array(
        v_operation_type,v_collection,v_legacy_id,v_base_version,v_payload
      )::text);
      perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(p_business_id::text||':'||p_device_id::text||':'||v_operation_id::text,0)
      );
      if not (select private.can_sync_collection(p_business_id,v_collection,'write')) then
        raise exception 'sync_collection_write_forbidden' using errcode='42501';
      end if;

      select so.result_payload,so.request_fingerprint into v_result,v_existing_fingerprint
      from public.sync_operations so
      where so.business_id=p_business_id and so.device_id=p_device_id and so.operation_id=v_operation_id;
      if found then
        if v_existing_fingerprint is distinct from v_request_fingerprint then
          raise exception 'sync_operation_id_reused_with_different_payload' using errcode='23505';
        end if;
        v_results:=v_results||jsonb_build_array(coalesce(v_result,jsonb_build_object(
          'operation_id',v_operation_id,'status','duplicate'
        )));
        continue;
      end if;

      select * into v_existing
      from private.business_state_records r
      where r.business_id=p_business_id and r.collection=v_collection and r.legacy_id=v_legacy_id
      for update;

      if found then
        v_record_id:=v_existing.id;
        v_current_version:=v_existing.version;
        if v_base_version is null or v_base_version<>v_current_version then
          v_result:=jsonb_build_object(
            'operation_id',v_operation_id,'collection',v_collection,'legacy_id',v_legacy_id,
            'status','conflict','current_version',v_current_version
          );
          insert into public.sync_operations(
            business_id,device_id,operation_id,request_fingerprint,operation_type,record_type,record_id,
            base_version,result_version,status,result_payload
          ) values (
            p_business_id,p_device_id,v_operation_id,v_request_fingerprint,v_operation_type,v_collection,v_record_id,
            v_base_version,v_current_version,'conflict',v_result
          );
          v_results:=v_results||jsonb_build_array(v_result);
          continue;
        end if;
        v_new_version:=v_current_version+1;
      else
        if v_operation_type='delete' then
          raise exception 'sync_record_not_found' using errcode='P0002';
        end if;
        if v_base_version is not null and v_base_version<>0 then
          v_result:=jsonb_build_object(
            'operation_id',v_operation_id,'collection',v_collection,'legacy_id',v_legacy_id,
            'status','conflict','current_version',0
          );
          insert into public.sync_operations(
            business_id,device_id,operation_id,request_fingerprint,operation_type,record_type,record_id,
            base_version,result_version,status,result_payload
          ) values (
            p_business_id,p_device_id,v_operation_id,v_request_fingerprint,v_operation_type,v_collection,null,
            v_base_version,0,'conflict',v_result
          );
          v_results:=v_results||jsonb_build_array(v_result);
          continue;
        end if;
        v_new_version:=1;
      end if;

      if v_operation_type='delete' then
        if v_collection in ('inv','serviceInv')
           and not (select private.has_business_permission(p_business_id,'sales.edit_draft')) then
          raise exception 'sales_edit_draft_forbidden' using errcode='42501';
        end if;
        if v_collection in ('inv','serviceInv') and coalesce(v_existing.payload_public->>'status','') in ('posted','final','voided') then
          raise exception 'posted_document_cannot_be_deleted' using errcode='42501';
        end if;
        if v_collection in ('inv','serviceInv') and v_existing.payload_private<>'{}'::jsonb and not v_cost_allowed then
          raise exception 'private_cost_document_cannot_be_deleted_by_this_role' using errcode='42501';
        end if;
        update private.business_state_records
          set deleted_at=now(),version=v_new_version,updated_at=now(),updated_by=v_user_id
        where business_id=p_business_id and id=v_record_id;
      else
        if v_payload is null or jsonb_typeof(v_payload)<>'object' then
          raise exception 'sync_payload_must_be_object' using errcode='22023';
        end if;
        if v_collection in ('inv','serviceInv')
           and lower(coalesce(nullif(btrim(v_payload->>'status'),''),'draft'))<>'draft' then
          raise exception 'document_sync_accepts_drafts_only' using errcode='42501';
        end if;
        if v_record_id is null or v_existing.deleted_at is not null then
          case v_collection
            when 'cust' then perform private.assert_feature_limit(p_business_id,'customers.total_limit',1);
            when 'prod' then perform private.assert_feature_limit(p_business_id,'products.total_limit',1);
            when 'services' then perform private.assert_feature_limit(p_business_id,'services.total_limit',1);
            when 'warehouses' then perform private.assert_feature_limit(p_business_id,'warehouses.total_limit',1);
            else null;
          end case;
        end if;

        if v_collection in ('inv','serviceInv') then
          if jsonb_typeof(v_payload->'items') is distinct from 'array'
             or jsonb_array_length(coalesce(v_payload->'items','[]'::jsonb))=0 then
            raise exception 'invoice_items_required' using errcode='22023';
          end if;
          -- Enforce the per-invoice item cap on create, update and restore alike.
          v_item_count:=jsonb_array_length(v_payload->'items');
          perform private.assert_feature_limit(p_business_id,'invoice.items.limit',v_item_count);
        end if;
        if v_collection in ('inv','serviceInv')
           and (v_record_id is null or v_existing.deleted_at is not null) then
          -- A restored invoice is a new active invoice and must consume the daily quota again.
          select coalesce(bs.timezone,'Asia/Tehran') into v_timezone
          from public.business_settings bs where bs.business_id=p_business_id;
          v_local_date:=(now() at time zone coalesce(v_timezone,'Asia/Tehran'))::date;
          perform private.consume_feature_quota(
            p_business_id,'invoices.daily_limit',v_local_date,v_operation_id
          );
        end if;
        if v_collection in ('inv','serviceInv') and v_record_id is not null then
          if not (select private.has_business_permission(p_business_id,'sales.edit_draft')) then
            raise exception 'sales_edit_draft_forbidden' using errcode='42501';
          end if;
          if not v_cost_allowed and v_existing.payload_private<>'{}'::jsonb
             and v_existing.payload_public->'items' is distinct from private.strip_sensitive_json(v_payload)->'items' then
            raise exception 'costed_document_items_are_immutable_for_this_role' using errcode='42501';
          end if;
        end if;

        v_payload_public:=private.strip_sensitive_json(v_payload);
        if v_cost_allowed then
          v_payload_private:=private.extract_sensitive_json(v_payload);
        elsif v_record_id is not null then
          v_payload_private:=v_existing.payload_private;
        else
          v_payload_private:='{}'::jsonb;
        end if;

        if v_record_id is null then
          insert into private.business_state_records(
            business_id,collection,legacy_id,payload_public,payload_private,
            version,created_at,updated_at,updated_by
          ) values (
            p_business_id,v_collection,v_legacy_id,v_payload_public,v_payload_private,
            1,now(),now(),v_user_id
          ) returning id into v_record_id;
        else
          update private.business_state_records
            set payload_public=v_payload_public,payload_private=v_payload_private,
                version=v_new_version,updated_at=now(),updated_by=v_user_id,deleted_at=null
          where business_id=p_business_id and id=v_record_id;
        end if;
      end if;

      insert into private.business_sync_counters(business_id,last_revision,updated_at)
      values (p_business_id,1,now())
      on conflict (business_id) do update
        set last_revision=private.business_sync_counters.last_revision+1,updated_at=now()
      returning last_revision into v_revision;

      insert into public.record_revisions(
        business_id,record_type,record_id,revision,changed_by,change_type,change_payload
      ) values (
        p_business_id,v_collection,v_record_id,v_revision,v_user_id,v_operation_type,
        jsonb_build_object('legacy_id',v_legacy_id,'version',v_new_version)
      );

      v_result:=jsonb_build_object(
        'operation_id',v_operation_id,'collection',v_collection,'legacy_id',v_legacy_id,
        'record_id',v_record_id,'status','applied','version',v_new_version,'revision',v_revision
      );
      insert into public.sync_operations(
        business_id,device_id,operation_id,request_fingerprint,operation_type,record_type,record_id,
        base_version,result_version,status,result_payload
      ) values (
        p_business_id,p_device_id,v_operation_id,v_request_fingerprint,v_operation_type,v_collection,v_record_id,
        v_base_version,v_new_version,'applied',v_result
      );
      v_results:=v_results||jsonb_build_array(v_result);
    exception when others then
      get stacked diagnostics v_error=message_text,v_state=returned_sqlstate;
      v_result:=jsonb_build_object(
        'operation_id',v_operation_id,'collection',v_collection,'legacy_id',v_legacy_id,
        'status','rejected','error_code',v_state,
        'message',case v_state
          when '42501' then 'operation_not_allowed'
          when '22023' then 'invalid_operation_data'
          when '23505' then 'duplicate_or_conflicting_operation'
          when '40001' then 'concurrent_change_retry'
          else 'operation_rejected'
        end
      );
      if v_operation_id is not null then
        insert into public.sync_operations(
          business_id,device_id,operation_id,request_fingerprint,operation_type,record_type,record_id,
          base_version,result_version,status,result_payload
        ) values (
          p_business_id,p_device_id,v_operation_id,v_request_fingerprint,coalesce(v_operation_type,'unknown'),
          coalesce(v_collection,'unknown'),v_record_id,v_base_version,null,'rejected',v_result
        ) on conflict (business_id,device_id,operation_id) do nothing;
      end if;
      v_results:=v_results||jsonb_build_array(v_result);
    end;
  end loop;
  return v_results;
end;
$fn$;

create or replace function private.sync_pull(
  p_business_id uuid,
  p_device_id uuid,
  p_since_revision bigint default 0,
  p_limit integer default 200
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  v_user_id uuid:=auth.uid();
  v_device public.sync_devices%rowtype;
  v_member_permission_version bigint;
  v_cost_allowed boolean;
  v_limit integer:=least(greatest(coalesce(p_limit,200),1),500);
  v_records jsonb;
  v_next_cursor bigint:=coalesce(p_since_revision,0);
  v_has_more boolean:=false;
  v_candidate_count integer:=0;
begin
  if v_user_id is null or not (select private.is_business_member(p_business_id)) then
    raise exception 'not_authorized' using errcode='42501';
  end if;
  if coalesce(p_since_revision,0)<0 then
    raise exception 'invalid_sync_cursor' using errcode='22023';
  end if;
  select * into v_device
  from public.sync_devices d
  where d.business_id=p_business_id and d.id=p_device_id
    and d.user_id=v_user_id and d.status='active'
  for update;
  if not found then raise exception 'sync_device_not_found' using errcode='42501'; end if;
  select permission_version into v_member_permission_version from public.business_members
  where business_id=p_business_id and user_id=v_user_id and status='active';
  if v_device.permission_version<>v_member_permission_version then
    update public.sync_devices set permission_version=v_member_permission_version
    where business_id=p_business_id and id=p_device_id;
    update public.sync_cursors set last_revision=0,last_synced_at=null
    where business_id=p_business_id and device_id=p_device_id;
    return jsonb_build_object('records','[]'::jsonb,'next_cursor',0,'has_more',true,'reset_required',true);
  end if;
  v_cost_allowed:=(select private.has_business_permission(p_business_id,'catalog.cost.read'));

  with latest as (
    select distinct on (r.record_id)
      r.record_id,r.record_type,r.revision,r.change_type
    from public.record_revisions r
    where r.business_id=p_business_id and r.revision>coalesce(p_since_revision,0)
    order by r.record_id,r.revision desc
  ),
  candidates as (
    select * from latest order by revision limit v_limit+1
  )
  select count(*) into v_candidate_count from candidates;

  v_has_more:=v_candidate_count>v_limit;

  -- Advance over every scanned revision, including collections this member cannot read.
  -- Otherwise a user without permission to the oldest changed collection can stall forever.
  with latest as (
    select distinct on (r.record_id)
      r.record_id,r.record_type,r.revision,r.change_type
    from public.record_revisions r
    where r.business_id=p_business_id and r.revision>coalesce(p_since_revision,0)
    order by r.record_id,r.revision desc
  ),
  scanned as (
    select * from latest order by revision limit v_limit
  ),
  visible as (
    select sc.record_id,sc.record_type,sc.revision,sc.change_type,
      s.collection,s.legacy_id,s.version,s.payload_public,s.payload_private,s.deleted_at
    from scanned sc
    join private.business_state_records s
      on s.business_id=p_business_id and s.id=sc.record_id
    where private.can_sync_collection(p_business_id,s.collection,'read')
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'record_id',v.record_id,'collection',v.collection,'legacy_id',v.legacy_id,
      'version',v.version,'revision',v.revision,'change_type',v.change_type,
      'deleted_at',v.deleted_at,
      'payload',case when v_cost_allowed
        then private.merge_sensitive_json(v.payload_public,v.payload_private)
        else v.payload_public end
    ) order by v.revision),'[]'::jsonb),
    coalesce((select max(sc.revision) from scanned sc),coalesce(p_since_revision,0))
  into v_records,v_next_cursor
  from visible v;

  update public.sync_cursors
    set last_revision=v_next_cursor,last_synced_at=now()
  where business_id=p_business_id and device_id=p_device_id;
  update public.sync_devices set last_seen_at=now()
  where business_id=p_business_id and id=p_device_id;

  return jsonb_build_object(
    'records',v_records,
    'next_cursor',v_next_cursor,
    'has_more',v_has_more,
    'reset_required',false
  );
end;
$fn$;

create or replace function public.register_sync_device(
  p_business_id uuid,
  p_device_name text,
  p_platform text,
  p_device_public_key jsonb default null
)
returns uuid
language sql
security invoker
set search_path = ''
as $fn$
  select private.register_sync_device(p_business_id,p_device_name,p_platform,p_device_public_key);
$fn$;

create or replace function public.sync_push(
  p_business_id uuid,
  p_device_id uuid,
  p_operations jsonb
)
returns jsonb
language sql
security invoker
set search_path = ''
as $fn$
  select private.sync_push(p_business_id,p_device_id,p_operations);
$fn$;

create or replace function public.sync_pull(
  p_business_id uuid,
  p_device_id uuid,
  p_since_revision bigint default 0,
  p_limit integer default 200
)
returns jsonb
language sql
security invoker
set search_path = ''
as $fn$
  select private.sync_pull(p_business_id,p_device_id,p_since_revision,p_limit);
$fn$;

revoke all on function private.strip_sensitive_json(jsonb) from public,anon,authenticated;
revoke all on function private.extract_sensitive_json(jsonb) from public,anon,authenticated;
revoke all on function private.merge_sensitive_json(jsonb,jsonb) from public,anon,authenticated;
revoke all on function private.can_sync_collection(uuid,text,text) from public,anon,authenticated;
revoke all on function private.register_sync_device(uuid,text,text,jsonb) from public,anon;
revoke all on function private.sync_push(uuid,uuid,jsonb) from public,anon;
revoke all on function private.sync_pull(uuid,uuid,bigint,integer) from public,anon;
grant execute on function private.register_sync_device(uuid,text,text,jsonb) to authenticated;
grant execute on function private.sync_push(uuid,uuid,jsonb) to authenticated;
grant execute on function private.sync_pull(uuid,uuid,bigint,integer) to authenticated;

revoke all on function public.register_sync_device(uuid,text,text,jsonb) from public,anon;
revoke all on function public.sync_push(uuid,uuid,jsonb) from public,anon;
revoke all on function public.sync_pull(uuid,uuid,bigint,integer) from public,anon;
grant execute on function public.register_sync_device(uuid,text,text,jsonb) to authenticated;
grant execute on function public.sync_push(uuid,uuid,jsonb) to authenticated;
grant execute on function public.sync_pull(uuid,uuid,bigint,integer) to authenticated;

commit;
