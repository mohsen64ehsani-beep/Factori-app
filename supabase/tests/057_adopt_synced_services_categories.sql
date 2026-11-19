-- 057: Catalog import adopts services created through the web/mobile bridge.
begin;
do $$
declare v_user uuid:='a0570000-0000-4000-8000-000000000001';v_business uuid;v_service uuid;v_result jsonb;v_catalog jsonb;
begin
 insert into auth.users(id,email,raw_user_meta_data) values(v_user,'factoori-service-adoption-ci@example.invalid','{"display_name":"Service Adoption CI"}'::jsonb) on conflict(id) do nothing;
 perform set_config('request.jwt.claim.sub',v_user::text,true);
 v_business:=public.create_business('Service Adoption CI');
 v_service:=public.web_create_service(v_business,'Already Synced Service 057','Test',57000);
 v_result:=public.web_import_legacy_supported_data(v_business,gen_random_uuid());
 v_catalog:=v_result->'catalog_import';
 if (v_catalog->>'imported_services')::integer<>1 or (v_catalog->>'conflicts')::integer<>0 then
  raise exception 'Catalog importer must adopt the matching web-created service: %',v_catalog;
 end if;
 if not exists(select 1 from private.legacy_normalized_record_map where business_id=v_business and legacy_collection='services' and legacy_id='value:Already Synced Service 057' and normalized_id=v_service and import_status='mapped') then
  raise exception 'Service legacy mapping was not recorded';
 end if;
end $$;
rollback;
