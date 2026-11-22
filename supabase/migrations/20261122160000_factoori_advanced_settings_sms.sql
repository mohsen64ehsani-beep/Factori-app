-- Factoori advanced web preferences and private SMS provider configuration.
-- This migration is bundled with the plugin; it is NOT auto-applied by WordPress.

create table if not exists private.business_sms_settings (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  provider text not null default 'farazsms' check (provider = 'farazsms'),
  username text,
  sender_number text,
  api_key text,
  enabled boolean not null default false,
  templates jsonb not null default '{}'::jsonb check (jsonb_typeof(templates) = 'object'),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

alter table private.business_sms_settings enable row level security;
revoke all on private.business_sms_settings from anon, authenticated;

create or replace function public.web_get_advanced_settings(p_business_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare v_settings jsonb;
begin
  if auth.uid() is null or not private.is_business_member(p_business_id) then
    raise exception using errcode='42501', message='Business access denied';
  end if;
  select coalesce(settings_json->'web_advanced','{}'::jsonb)
    into v_settings
  from public.business_settings
  where business_id=p_business_id;
  return coalesce(v_settings,'{}'::jsonb);
end;
$function$;

create or replace function public.web_update_advanced_settings(
  p_business_id uuid,
  p_settings jsonb
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare v_entitlement jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode='28000', message='Authentication required';
  end if;
  if not private.has_business_permission(p_business_id,'settings.manage') then
    raise exception using errcode='42501', message='Business settings management is not permitted';
  end if;
  v_entitlement:=public.get_business_entitlements(p_business_id);
  if coalesce(v_entitlement->>'is_premium','false')<>'true' then
    raise exception using errcode='42501', message='Premium license required';
  end if;
  if p_settings is null or jsonb_typeof(p_settings)<>'object'
     or pg_column_size(p_settings)>20000 then
    raise exception using errcode='22023', message='Invalid advanced settings payload';
  end if;
  insert into public.business_settings as current_settings(business_id,settings_json,updated_at)
  values(p_business_id,jsonb_build_object('web_advanced',p_settings),now())
  on conflict(business_id) do update
    set settings_json=coalesce(current_settings.settings_json,'{}'::jsonb)
                       || jsonb_build_object('web_advanced',p_settings),
        updated_at=now();
  return true;
end;
$function$;

create or replace function public.web_get_sms_settings(p_business_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare v_row private.business_sms_settings%rowtype;
begin
  if auth.uid() is null or not private.is_business_member(p_business_id) then
    raise exception using errcode='42501', message='Business access denied';
  end if;
  select * into v_row from private.business_sms_settings where business_id=p_business_id;
  if not found then
    return jsonb_build_object('provider','farazsms','enabled',false,'api_key_configured',false,'templates','{}'::jsonb);
  end if;
  return jsonb_build_object(
    'provider',v_row.provider,
    'username',v_row.username,
    'sender_number',v_row.sender_number,
    'enabled',v_row.enabled,
    'api_key_configured',(coalesce(v_row.api_key,'')<>''),
    'templates',v_row.templates
  );
end;
$function$;

create or replace function public.web_save_sms_settings(
  p_business_id uuid,
  p_provider text,
  p_username text,
  p_sender_number text,
  p_api_key text,
  p_clear_api_key boolean,
  p_enabled boolean,
  p_templates jsonb
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $function$
declare v_entitlement jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode='28000', message='Authentication required';
  end if;
  if not private.has_business_permission(p_business_id,'settings.manage') then
    raise exception using errcode='42501', message='Business settings management is not permitted';
  end if;
  v_entitlement:=public.get_business_entitlements(p_business_id);
  if coalesce(v_entitlement->>'is_premium','false')<>'true' then
    raise exception using errcode='42501', message='Premium license required';
  end if;
  if p_provider<>'farazsms'
     or length(coalesce(p_username,''))>160
     or length(coalesce(p_sender_number,''))>40
     or length(coalesce(p_api_key,''))>500
     or p_enabled is null
     or p_templates is null or jsonb_typeof(p_templates)<>'object'
     or pg_column_size(p_templates)>10000 then
    raise exception using errcode='22023', message='Invalid SMS settings';
  end if;
  insert into private.business_sms_settings as current_sms(
    business_id,provider,username,sender_number,api_key,enabled,templates,updated_by,updated_at
  ) values (
    p_business_id,p_provider,nullif(btrim(p_username),''),nullif(btrim(p_sender_number),''),
    case when coalesce(p_clear_api_key,false) then null else nullif(p_api_key,'') end,
    p_enabled,p_templates,auth.uid(),now()
  )
  on conflict(business_id) do update set
    provider=excluded.provider,
    username=excluded.username,
    sender_number=excluded.sender_number,
    api_key=case
      when coalesce(p_clear_api_key,false) then null
      when coalesce(p_api_key,'')<>'' then p_api_key
      else current_sms.api_key
    end,
    enabled=excluded.enabled,
    templates=excluded.templates,
    updated_by=auth.uid(),
    updated_at=now();
  return true;
end;
$function$;

revoke all on function public.web_get_advanced_settings(uuid) from public, anon;
revoke all on function public.web_update_advanced_settings(uuid,jsonb) from public, anon;
revoke all on function public.web_get_sms_settings(uuid) from public, anon;
revoke all on function public.web_save_sms_settings(uuid,text,text,text,text,boolean,boolean,jsonb) from public, anon;
grant execute on function public.web_get_advanced_settings(uuid) to authenticated;
grant execute on function public.web_update_advanced_settings(uuid,jsonb) to authenticated;
grant execute on function public.web_get_sms_settings(uuid) to authenticated;
grant execute on function public.web_save_sms_settings(uuid,text,text,text,text,boolean,boolean,jsonb) to authenticated;
