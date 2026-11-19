begin;
alter table public.business_settings
  add column if not exists currency_display_unit text not null default 'rial';
alter table public.business_settings
  drop constraint if exists business_settings_currency_display_unit_check;
alter table public.business_settings
  add constraint business_settings_currency_display_unit_check
  check (currency_display_unit in ('rial','toman'));

create or replace function public.web_sync_currency_display_unit(p_business_id uuid,p_display_unit text)
returns boolean
language plpgsql
security definer
set search_path=''
as $$
begin
  if auth.uid() is null then
    raise exception using errcode='28000',message='Authentication required';
  end if;
  if p_display_unit not in ('rial','toman') then
    raise exception using errcode='22023',message='Invalid currency display unit';
  end if;
  if not private.has_business_permission(p_business_id,'settings.manage') then
    raise exception using errcode='42501',message='Business settings management is not permitted';
  end if;
  insert into public.business_settings(business_id,currency_display_unit)
  values(p_business_id,p_display_unit)
  on conflict(business_id) do update
    set currency_display_unit=excluded.currency_display_unit,updated_at=now();
  return true;
end;
$$;
revoke all on function public.web_sync_currency_display_unit(uuid,text) from public,anon;
grant execute on function public.web_sync_currency_display_unit(uuid,text) to authenticated;
commit;