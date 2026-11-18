-- 030: Legacy fiscal periods remain closed after normalized import.
begin;

do $test$
declare
 v_owner uuid:='ad000000-0000-4000-8000-000000000001';
 v_outsider uuid:='ad000000-0000-4000-8000-000000000002';
 v_business uuid:='ae000000-0000-4000-8000-000000000001';
 v_other_business uuid:='ae000000-0000-4000-8000-000000000002';
 v_generation uuid:='af000000-0000-4000-8000-000000000001';
 v_result jsonb;
 v_period_id uuid;
 v_failed boolean:=false;
begin
 insert into auth.users(id,email,email_confirmed_at)
 values(v_owner,'legacy-fiscal-owner@example.test',now()),(v_outsider,'legacy-fiscal-outsider@example.test',now())
 on conflict(id) do nothing;
 insert into public.businesses(id,name,owner_user_id)
 values(v_business,'Legacy fiscal business',v_owner),(v_other_business,'Other fiscal business',v_outsider)
 on conflict(id) do nothing;
 insert into public.business_members(business_id,user_id,role_code,status,joined_at)
 values(v_business,v_owner,'owner','active',now()),(v_other_business,v_outsider,'owner','active',now())
 on conflict(business_id,user_id) do nothing;

 insert into private.business_state_records(business_id,collection,legacy_id,payload_public,updated_by)
 values
  (v_business,'fiscal','legacy-fiscal-1',
   '{"id":"legacy-fiscal-1","title":"Closed 1404","from":"2025-03-21","to":"2026-03-20","note":"legacy close"}',v_owner);

 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_result:=public.import_legacy_fiscal_periods(v_business,v_generation);
 if (v_result->>'imported_periods')::integer<>1 then
  raise exception 'Fiscal period import failed: %',v_result;
 end if;
 select normalized_id into v_period_id from private.legacy_normalized_record_map
 where business_id=v_business and legacy_collection='fiscal' and legacy_id='legacy-fiscal-1';
 if not exists(select 1 from public.fiscal_periods where business_id=v_business and id=v_period_id
  and title='Closed 1404' and date_from='2025-03-21' and date_to='2026-03-20' and status='closed') then
  raise exception 'Legacy fiscal lock was not preserved as a closed normalized period';
 end if;
 v_result:=public.import_legacy_fiscal_periods(v_business,v_generation);
 if (v_result->>'unchanged')::integer<>1 then
  raise exception 'Repeated fiscal import must be a no-op: %',v_result;
 end if;

 update private.business_state_records
 set payload_public=payload_public||'{"title":"Changed title"}'::jsonb
 where business_id=v_business and collection='fiscal' and legacy_id='legacy-fiscal-1';
 v_result:=public.import_legacy_fiscal_periods(v_business,'af000000-0000-4000-8000-000000000002');
 if (v_result->>'conflicts')::integer<>1 then
  raise exception 'Changed fiscal source must be flagged as conflict: %',v_result;
 end if;
 if (select title from public.fiscal_periods where business_id=v_business and id=v_period_id)<>'Closed 1404' then
  raise exception 'Changed legacy fiscal period must not overwrite normalized period';
 end if;

 v_failed:=false;
 perform set_config('request.jwt.claim.sub',v_outsider::text,true);
 begin
  perform public.import_legacy_fiscal_periods(v_business,'af000000-0000-4000-8000-000000000003');
 exception when insufficient_privilege then v_failed:=true;
 end;
 if not v_failed then raise exception 'Cross-business fiscal import must be denied'; end if;
end;
$test$;

rollback;
