begin;

create or replace function public.web_list_legacy_collections(p_business_id uuid, p_collections text[])
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
 v_result jsonb:='{}'::jsonb;
 v_collection text;
 v_permission text;
 v_cost_allowed boolean;
 v_rows jsonb;
begin
 if auth.uid() is null then
  raise exception using errcode='28000',message='Authentication required';
 end if;
 if p_collections is null or cardinality(p_collections)=0 or cardinality(p_collections)>24 then
  raise exception using errcode='22023',message='Select between 1 and 24 legacy collections';
 end if;
 v_cost_allowed:=private.has_business_permission(p_business_id,'catalog.cost.read');
 foreach v_collection in array p_collections loop
  v_permission:=case
   when v_collection in ('cust','suppliers','duedates','inv','serviceInv','returns','debt','fiscal') then 'sales.read'
   when v_collection in ('pay','creditors','creditorPayments','purchases','supplierPayments','expenses','otherincome','moneytransfers','accounts') then 'payments.read'
   when v_collection in ('prod','services','categories') then 'catalog.read'
   when v_collection in ('warehouses','wastage','stockMoves','warehouseStocks','transfers','opening') then 'inventory.read'
   when v_collection='smsHistory' then 'business.read' else null end;
  if v_permission is null then
   raise exception using errcode='22023',message='Unsupported legacy collection';
  end if;
  if not private.has_business_permission(p_business_id,v_permission) then
   raise exception using errcode='42501',message='Legacy collection read permission denied';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'legacy_id',r.legacy_id,
    'normalized_id',case when m.import_status='mapped' then m.normalized_id else null end,
    'target_table',case when m.import_status='mapped' then m.target_table else null end,
    'import_status',m.import_status,
    'payload',case when v_cost_allowed then private.merge_sensitive_json(r.payload_public,r.payload_private) else r.payload_public end,
    'version',r.version,
    'updated_at',r.updated_at
  ) order by r.updated_at desc),'[]'::jsonb)
  into v_rows
  from private.business_state_records r
  left join private.legacy_normalized_record_map m
    on m.business_id=r.business_id
   and m.legacy_collection=r.collection
   and m.legacy_id=r.legacy_id
  where r.business_id=p_business_id
    and r.collection=v_collection
    and r.deleted_at is null;
  v_result:=v_result||jsonb_build_object(v_collection,coalesce(v_rows,'[]'::jsonb));
 end loop;
 return v_result;
end;
$function$;

revoke all on function public.web_list_legacy_collections(uuid,text[]) from public,anon;
grant execute on function public.web_list_legacy_collections(uuid,text[]) to authenticated;

commit;