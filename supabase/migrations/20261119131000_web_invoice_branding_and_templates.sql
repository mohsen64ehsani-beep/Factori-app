alter table public.business_settings
 add column if not exists invoice_logo_url text,
 add column if not exists invoice_signature_url text,
 add column if not exists invoice_template text not null default 'modern',
 add column if not exists invoice_footer text;

do $$
begin
 if not exists(select 1 from pg_constraint where conrelid='public.business_settings'::regclass and conname='business_settings_invoice_template_check') then
  alter table public.business_settings add constraint business_settings_invoice_template_check check(invoice_template in ('modern','classic','minimal'));
 end if;
 if not exists(select 1 from pg_constraint where conrelid='public.business_settings'::regclass and conname='business_settings_invoice_logo_url_check') then
  alter table public.business_settings add constraint business_settings_invoice_logo_url_check check(invoice_logo_url is null or (invoice_logo_url ~ '^https://[^[:space:]]+$' and length(invoice_logo_url)<=2048));
 end if;
 if not exists(select 1 from pg_constraint where conrelid='public.business_settings'::regclass and conname='business_settings_invoice_signature_url_check') then
  alter table public.business_settings add constraint business_settings_invoice_signature_url_check check(invoice_signature_url is null or (invoice_signature_url ~ '^https://[^[:space:]]+$' and length(invoice_signature_url)<=2048));
 end if;
 if not exists(select 1 from pg_constraint where conrelid='public.business_settings'::regclass and conname='business_settings_invoice_footer_check') then
  alter table public.business_settings add constraint business_settings_invoice_footer_check check(invoice_footer is null or length(invoice_footer)<=500);
 end if;
end $$;

create or replace function public.web_update_invoice_branding(
 p_business_id uuid,p_logo_url text,p_signature_url text,p_template text,p_footer text default null
)
returns boolean language plpgsql security definer set search_path=''
as $function$
declare v_user uuid:=auth.uid();
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required';end if;
 if not private.has_business_permission(p_business_id,'settings.manage') then raise exception using errcode='42501',message='Invoice branding management is not permitted';end if;
 if coalesce(p_template,'') not in ('modern','classic','minimal')
  or (p_logo_url is not null and (p_logo_url !~ '^https://[^[:space:]]+$' or length(p_logo_url)>2048))
  or (p_signature_url is not null and (p_signature_url !~ '^https://[^[:space:]]+$' or length(p_signature_url)>2048))
  or length(coalesce(p_footer,''))>500 then
  raise exception using errcode='22023',message='Invalid invoice branding settings';
 end if;
 insert into public.business_settings(business_id,invoice_logo_url,invoice_signature_url,invoice_template,invoice_footer,updated_at)
 values(p_business_id,nullif(btrim(coalesce(p_logo_url,'')),''),nullif(btrim(coalesce(p_signature_url,'')),''),p_template,nullif(btrim(coalesce(p_footer,'')),''),now())
 on conflict(business_id) do update set invoice_logo_url=excluded.invoice_logo_url,invoice_signature_url=excluded.invoice_signature_url,
 invoice_template=excluded.invoice_template,invoice_footer=excluded.invoice_footer,updated_at=now();
 return true;
end;$function$;
revoke all on function public.web_update_invoice_branding(uuid,text,text,text,text) from public,anon;
grant execute on function public.web_update_invoice_branding(uuid,text,text,text,text) to authenticated;
