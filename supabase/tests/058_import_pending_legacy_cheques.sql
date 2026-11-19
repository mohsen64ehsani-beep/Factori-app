-- 058: Pending legacy received and issued cheques import into normalized cheque records.
begin;
do $$
declare v_user uuid:='a0580000-0000-4000-8000-000000000001';v_business uuid;v_customer uuid;v_supplier uuid;v_result jsonb;v_count integer;
begin
 insert into auth.users(id,email,raw_user_meta_data) values(v_user,'factoori-cheque-import-ci@example.invalid','{"display_name":"Cheque Import CI"}'::jsonb) on conflict(id) do nothing;
 perform set_config('request.jwt.claim.sub',v_user::text,true);
 v_business:=public.create_business('Cheque Import CI');
 v_customer:=public.web_create_contact(v_business,'customer','Cheque Import Customer 058',null,null,null,null);
 v_supplier:=public.web_create_contact(v_business,'supplier','Cheque Import Supplier 058',null,null,null,null);
 insert into private.business_state_records(business_id,collection,legacy_id,payload_public,updated_by)
 values
  (v_business,'pay','received-cheque-058',jsonb_build_object('id','received-cheque-058','cid',(select legacy_id from public.contacts where id=v_customer),'kind','cheque','amt',58000,'dt',current_date::text,'no','RC-058','cdt',(current_date+14)::text,'bank','Test Bank','status','pending','note','Received pending cheque'),v_user),
  (v_business,'supplierPayments','issued-cheque-058',jsonb_build_object('id','issued-cheque-058','supplierId',(select legacy_id from public.contacts where id=v_supplier),'amount',39000,'dt',current_date::text,'method','cheque','no','IC-058','cdt',(current_date+14)::text,'bank','Test Bank','status','pending','note','Issued pending cheque'),v_user);
 v_result:=public.import_legacy_cash_financial_records(v_business,gen_random_uuid());
 if (v_result->>'imported')::integer<>2 then raise exception 'Pending cheques did not import: %',v_result; end if;
 select count(*) into v_count from public.cheques where business_id=v_business;
 if v_count<>2 then raise exception 'Normalized cheque count mismatch: %',v_count; end if;
 if not exists(select 1 from public.cheques where business_id=v_business and cheque_direction='received' and cheque_number='RC-058' and status='pending') then raise exception 'Received cheque mapping incorrect';end if;
 if not exists(select 1 from public.cheques where business_id=v_business and cheque_direction='issued' and cheque_number='IC-058' and status='pending') then raise exception 'Issued cheque mapping incorrect';end if;
end $$;
rollback;
