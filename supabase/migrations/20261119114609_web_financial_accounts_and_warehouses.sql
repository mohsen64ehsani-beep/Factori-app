create or replace function public.web_create_financial_account(
  p_business_id uuid,
  p_name text,
  p_account_type text,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user uuid := auth.uid();
  v_legacy_id text := gen_random_uuid()::text;
  v_account_id uuid;
  v_chart_account_id uuid;
  v_chart_code text;
  v_is_default boolean;
begin
  if v_user is null then
    raise exception using errcode='28000', message='Authentication required';
  end if;
  if not private.has_business_permission(p_business_id,'settings.manage') then
    raise exception using errcode='42501', message='Financial account management is not permitted';
  end if;
  if length(btrim(coalesce(p_name,''))) not between 1 and 120
     or p_account_type not in ('cash','bank')
     or length(btrim(coalesce(p_note,''))) > 500 then
    raise exception using errcode='22023', message='Invalid financial account details';
  end if;

  v_chart_code := case p_account_type when 'cash' then '1000' else '1010' end;
  select ca.id into v_chart_account_id
  from public.chart_of_accounts ca
  where ca.business_id=p_business_id and ca.code=v_chart_code
    and ca.account_class='asset' and ca.is_active and ca.allow_posting
  limit 1;
  if v_chart_account_id is null then
    raise exception using errcode='55000', message='Default ledger account for this financial account type is not configured';
  end if;

  select not exists (
    select 1 from public.financial_accounts fa
    where fa.business_id=p_business_id and fa.is_active
  ) into v_is_default;

  insert into public.financial_accounts(
    business_id,name,account_type,currency_code,is_active,is_default,
    opening_balance,legacy_id,created_by
  ) values (
    p_business_id,btrim(p_name),p_account_type,'IRR',true,v_is_default,
    0,v_legacy_id,v_user
  ) returning id into v_account_id;

  insert into public.financial_account_ledger_map(
    business_id,financial_account_id,chart_account_id,created_by
  ) values(p_business_id,v_account_id,v_chart_account_id,v_user);

  perform private.write_legacy_master_record(
    p_business_id,'accounts',v_legacy_id,
    jsonb_strip_nulls(jsonb_build_object(
      'id',v_legacy_id,'name',btrim(p_name),'type',p_account_type,
      'note',nullif(btrim(coalesce(p_note,'')),'')
    )),false,v_user
  );
  return v_account_id;
end;
$function$;

create or replace function public.web_create_warehouse(
  p_business_id uuid,
  p_name text,
  p_code text default null,
  p_address text default null,
  p_note text default null,
  p_is_default boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user uuid := auth.uid();
  v_id uuid := gen_random_uuid();
  v_code text;
  v_is_default boolean;
begin
  if v_user is null then
    raise exception using errcode='28000', message='Authentication required';
  end if;
  if not private.has_business_permission(p_business_id,'inventory.adjust') then
    raise exception using errcode='42501', message='Warehouse management is not permitted';
  end if;
  if length(btrim(coalesce(p_name,''))) not between 1 and 120
     or length(btrim(coalesce(p_code,''))) > 40
     or length(btrim(coalesce(p_address,''))) > 500
     or length(btrim(coalesce(p_note,''))) > 500 then
    raise exception using errcode='22023', message='Invalid warehouse details';
  end if;

  select p_is_default or not exists(
    select 1 from public.warehouses w
    where w.business_id=p_business_id and w.is_active
  ) into v_is_default;

  if v_is_default then
    update public.warehouses set is_default=false,updated_at=now()
    where business_id=p_business_id and is_default;
  end if;

  v_code := coalesce(
    nullif(btrim(coalesce(p_code,'')),''),
    'WH-'||upper(left(replace(v_id::text,'-',''),8))
  );

  insert into public.warehouses(
    id,business_id,name,code,address,is_default,is_active
  ) values (
    v_id,p_business_id,btrim(p_name),v_code,
    nullif(btrim(coalesce(p_address,'')),''),v_is_default,true
  );

  perform private.write_legacy_master_record(
    p_business_id,'warehouses',v_id::text,
    jsonb_strip_nulls(jsonb_build_object(
      'id',v_id::text,'name',btrim(p_name),
      'address',nullif(btrim(coalesce(p_address,'')),''),
      'note',nullif(btrim(coalesce(p_note,'')),'')
    )),false,v_user
  );
  return v_id;
end;
$function$;

revoke all on function public.web_create_financial_account(uuid,text,text,text) from public,anon;
grant execute on function public.web_create_financial_account(uuid,text,text,text) to authenticated;
revoke all on function public.web_create_warehouse(uuid,text,text,text,text,boolean) from public,anon;
grant execute on function public.web_create_warehouse(uuid,text,text,text,text,boolean) to authenticated;
