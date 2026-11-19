create or replace function public.web_list_legacy_invoices(p_business_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_cost_allowed boolean;
begin
  if auth.uid() is null or not private.has_business_permission(p_business_id,'sales.read') then
    raise exception using errcode='42501',message='Sales read permission denied';
  end if;
  v_cost_allowed := private.has_business_permission(p_business_id,'catalog.cost.read');
  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'legacy_id',r.legacy_id,
        'normalized_id',case when m.import_status='mapped' and m.target_table='documents' then m.normalized_id else null end,
        'payload',case when v_cost_allowed then private.merge_sensitive_json(r.payload_public,r.payload_private) else r.payload_public end,
        'version',r.version,
        'updated_at',r.updated_at
      ) order by r.updated_at desc
    )
    from private.business_state_records r
    left join private.legacy_normalized_record_map m
      on m.business_id=r.business_id
     and m.legacy_collection='inv'
     and m.legacy_id=r.legacy_id
    where r.business_id=p_business_id
      and r.collection='inv'
      and r.deleted_at is null
  ),'[]'::jsonb);
end;
$function$;