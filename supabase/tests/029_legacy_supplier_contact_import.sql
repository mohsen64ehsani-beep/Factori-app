-- 029: Legacy suppliers are normalized as supplier contacts without importing payments.
begin;

do $test$
declare
 v_owner uuid:='aa000000-0000-4000-8000-000000000001';
 v_outsider uuid:='aa000000-0000-4000-8000-000000000002';
 v_business uuid:='ab000000-0000-4000-8000-000000000001';
 v_other_business uuid:='ab000000-0000-4000-8000-000000000002';
 v_generation uuid:='ac000000-0000-4000-8000-000000000001';
 v_result jsonb;
 v_supplier_id uuid;
 v_failed boolean:=false;
begin
 insert into auth.users(id,email,email_confirmed_at)
 values(v_owner,'legacy-supplier-owner@example.test',now()),(v_outsider,'legacy-supplier-outsider@example.test',now())
 on conflict(id) do nothing;
 insert into public.businesses(id,name,owner_user_id)
 values(v_business,'Legacy supplier business',v_owner),(v_other_business,'Other supplier business',v_outsider)
 on conflict(id) do nothing;
 insert into public.business_members(business_id,user_id,role_code,status,joined_at)
 values(v_business,v_owner,'owner','active',now()),(v_other_business,v_outsider,'owner','active',now())
 on conflict(business_id,user_id) do nothing;

 insert into private.business_state_records(business_id,collection,legacy_id,payload_public,updated_by)
 values
  (v_business,'suppliers','legacy-supplier-1',
   '{"id":"legacy-supplier-1","name":"Supplier One","phone":"09120000001","address":"Warehouse Road","note":"preferred"}',v_owner),
  (v_business,'supplierPayments','legacy-supplier-payment',
   '{"id":"legacy-supplier-payment","supplierId":"legacy-supplier-1","amount":500}',v_owner);

 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_result:=public.import_legacy_supplier_contacts(v_business,v_generation);
 if (v_result->>'imported_suppliers')::integer<>1 then
  raise exception 'Supplier contact import failed: %',v_result;
 end if;
 select normalized_id into v_supplier_id from private.legacy_normalized_record_map
 where business_id=v_business and legacy_collection='suppliers' and legacy_id='legacy-supplier-1';
 if not exists(select 1 from public.contacts where business_id=v_business and id=v_supplier_id
  and contact_type='supplier' and name='Supplier One' and phone='09120000001'
  and address='Warehouse Road') then
  raise exception 'Supplier contact fields or type were not normalized correctly';
 end if;
 if exists(select 1 from public.financial_transactions where business_id=v_business)
  or exists(select 1 from public.contact_ledger_entries where business_id=v_business) then
  raise exception 'Supplier import must not create supplier payments or ledger postings';
 end if;
 v_result:=public.import_legacy_supplier_contacts(v_business,v_generation);
 if (v_result->>'unchanged')::integer<>1 then
  raise exception 'Repeated supplier import must be a no-op: %',v_result;
 end if;

 update private.business_state_records
 set payload_public=payload_public||'{"phone":"09120000002"}'::jsonb
 where business_id=v_business and collection='suppliers' and legacy_id='legacy-supplier-1';
 v_result:=public.import_legacy_supplier_contacts(v_business,'ac000000-0000-4000-8000-000000000002');
 if (v_result->>'conflicts')::integer<>1 then
  raise exception 'Changed supplier source must be flagged as conflict: %',v_result;
 end if;
 if (select phone from public.contacts where business_id=v_business and id=v_supplier_id)<>'09120000002' then
  raise exception 'Changed legacy supplier must be reflected by the bidirectional sync bridge';
 end if;

 v_failed:=false;
 perform set_config('request.jwt.claim.sub',v_outsider::text,true);
 begin
  perform public.import_legacy_supplier_contacts(v_business,'ac000000-0000-4000-8000-000000000003');
 exception when insufficient_privilege then v_failed:=true;
 end;
 if not v_failed then raise exception 'Cross-business supplier import must be denied'; end if;
end;
$test$;

rollback;
