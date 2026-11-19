alter function public.web_export_business_backup(uuid) rename to web_export_business_backup_v1;

create or replace function public.web_export_business_backup(p_business_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare v_backup jsonb;v_branding jsonb;
begin
 v_backup:=public.web_export_business_backup_v1(p_business_id);
 select jsonb_build_object(
  'invoice_logo_url',invoice_logo_url,
  'invoice_signature_url',invoice_signature_url,
  'invoice_template',invoice_template,
  'invoice_footer',invoice_footer
 ) into v_branding from public.business_settings where business_id=p_business_id;
 v_backup:=jsonb_set(
  v_backup,
  '{data,business_settings}',
  coalesce(v_backup #> '{data,business_settings}','{}'::jsonb)||coalesce(v_branding,'{}'::jsonb),
  true
 );
 return v_backup;
end;$function$;
revoke all on function public.web_export_business_backup_v1(uuid) from public,anon;
grant execute on function public.web_export_business_backup_v1(uuid) to authenticated;
revoke all on function public.web_export_business_backup(uuid) from public,anon;
grant execute on function public.web_export_business_backup(uuid) to authenticated;
