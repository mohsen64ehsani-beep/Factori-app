-- 044: Web legacy collection reads enforce collection allowlists and business permissions.
begin;
do $$
declare
 v_user uuid:='a0440000-0000-4000-8000-000000000001';v_business uuid;v_data jsonb;
begin
 insert into auth.users(id,email,raw_user_meta_data) values(v_user,'factoori-legacy-read-ci@example.invalid','{"display_name":"Legacy Read CI"}'::jsonb) on conflict(id) do nothing;
 perform set_config('request.jwt.claim.sub',v_user::text,true);
 v_business:=public.create_business('Legacy Read CI');
 insert into private.business_state_records(business_id,collection,legacy_id,payload_public,updated_by)
 values(v_business,'pay','legacy-pay-044','{"id":"legacy-pay-044","amt":1000,"dt":"2026-11-18"}'::jsonb,v_user);
 v_data:=public.web_list_legacy_collections(v_business,array['pay']);
 if jsonb_array_length(v_data->'pay')<>1 then raise exception 'Legacy payment collection was not returned'; end if;
 begin
  perform public.web_list_legacy_collections(v_business,array['not-a-collection']);
  raise exception 'Unsupported collection should have been rejected';
 exception when sqlstate '22023' then null; end;
end $$;
rollback;