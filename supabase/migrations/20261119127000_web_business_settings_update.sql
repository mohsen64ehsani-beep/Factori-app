create or replace function public.web_update_business_settings(
 p_business_id uuid,
 p_currency_code text,
 p_currency_scale integer,
 p_timezone text,
 p_date_calendar text,
 p_costing_method text,
 p_tax_enabled boolean,
 p_default_tax_rate numeric,
 p_negative_stock_allowed boolean
)
returns boolean language plpgsql security definer set search_path=''
as $function$
declare
 v_user uuid:=auth.uid();v_old public.business_settings%rowtype;v_exists boolean;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required';end if;
 if not private.has_business_permission(p_business_id,'settings.manage') then raise exception using errcode='42501',message='Business settings management is not permitted';end if;
 if coalesce(p_currency_code,'') !~ '^[A-Z]{3}$'
  or p_currency_scale not in (1,10,100,1000,10000)
  or coalesce(p_timezone,'')='' or not exists(select 1 from pg_timezone_names z where z.name=p_timezone)
  or coalesce(p_date_calendar,'') not in ('jalali','gregorian')
  or coalesce(p_costing_method,'') not in ('weighted_average','fifo')
  or p_tax_enabled is null or coalesce(p_default_tax_rate,-1)<0 or p_default_tax_rate>100
  or p_negative_stock_allowed is null then
  raise exception using errcode='22023',message='Invalid business settings';
 end if;
 select * into v_old from public.business_settings where business_id=p_business_id for update;
 v_exists:=found;
 if v_exists and (v_old.currency_code<>p_currency_code or v_old.currency_scale<>p_currency_scale)
  and (exists(select 1 from public.financial_transactions t where t.business_id=p_business_id and t.status='posted')
   or exists(select 1 from public.documents d where d.business_id=p_business_id and d.status='posted')) then
  raise exception using errcode='55000',message='Currency and precision cannot change after posted financial or invoice activity';
 end if;
 if v_exists and v_old.costing_method<>p_costing_method
  and exists(select 1 from public.stock_movements sm where sm.business_id=p_business_id) then
  raise exception using errcode='55000',message='Inventory costing method cannot change after stock movements exist';
 end if;
 insert into public.business_settings(
  business_id,currency_code,currency_scale,timezone,date_calendar,costing_method,
  tax_enabled,default_tax_rate,negative_stock_allowed,updated_at
 ) values(
  p_business_id,p_currency_code,p_currency_scale,p_timezone,p_date_calendar,p_costing_method,
  p_tax_enabled,p_default_tax_rate,p_negative_stock_allowed,now()
 )
 on conflict(business_id) do update set
  currency_code=excluded.currency_code,currency_scale=excluded.currency_scale,
  timezone=excluded.timezone,date_calendar=excluded.date_calendar,
  costing_method=excluded.costing_method,tax_enabled=excluded.tax_enabled,
  default_tax_rate=excluded.default_tax_rate,
  negative_stock_allowed=excluded.negative_stock_allowed,updated_at=now();
 return true;
end;$function$;
revoke all on function public.web_update_business_settings(uuid,text,integer,text,text,text,boolean,numeric,boolean) from public,anon;
grant execute on function public.web_update_business_settings(uuid,text,integer,text,text,text,boolean,numeric,boolean) to authenticated;
