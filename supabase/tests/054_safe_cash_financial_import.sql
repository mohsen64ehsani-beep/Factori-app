-- 054: Safe legacy cash receipts and payments import idempotently into the normalized ledger.
begin;
do $$
declare v_user uuid:='a0540000-0000-4000-8000-000000000001';v_business uuid;v_customer uuid;v_supplier uuid;v_account uuid;v_result jsonb;v_count integer;
begin
 insert into auth.users(id,email,raw_user_meta_data) values(v_user,'factoori-financial-import-ci@example.invalid','{"display_name":"Financial Import CI"}'::jsonb) on conflict(id) do nothing;
 perform set_config('request.jwt.claim.sub',v_user::text,true);
 v_business:=public.create_business('Financial Import CI');
 v_customer:=public.web_create_contact(v_business,'customer','Cash Import Customer 054',null,null,null,null);
 v_supplier:=public.web_create_contact(v_business,'supplier','Cash Import Supplier 054',null,null,null,null);
 select id into v_account from public.financial_accounts where business_id=v_business and is_active and is_default limit 1;
 insert into private.business_state_records(business_id,collection,legacy_id,payload_public,updated_by)
 values
  (v_business,'pay','pay-cash-054',jsonb_build_object('id','pay-cash-054','cid',(select legacy_id from public.contacts where id=v_customer),'kind','cash','amt',10000,'dt',current_date::text,'accountId','factoori:system-default-cash:v1','status','received','note','Legacy cash receipt'),v_user),
  (v_business,'supplierPayments','supplier-cash-054',jsonb_build_object('id','supplier-cash-054','supplierId',(select legacy_id from public.contacts where id=v_supplier),'amount',4000,'dt',current_date::text,'method','cash','accountId','factoori:system-default-cash:v1','note','Legacy supplier payment'),v_user),
  (v_business,'expenses','expense-cash-054',jsonb_build_object('id','expense-cash-054','title','Legacy expense','amt',2000,'dt',current_date::text,'accountId','factoori:system-default-cash:v1'),v_user),
  (v_business,'otherincome','income-cash-054',jsonb_build_object('id','income-cash-054','title','Legacy income','amount',3000,'dt',current_date::text,'accountId','factoori:system-default-cash:v1'),v_user);
 v_result:=public.import_legacy_cash_financial_records(v_business,'a0540000-0000-4000-8000-000000000054');
 if (v_result->>'imported')::integer<>4 then raise exception 'Expected four cash ledger imports: %',v_result; end if;
 select count(*) into v_count from public.financial_transactions where business_id=v_business;
 if v_count<>4 then raise exception 'Normalized ledger transaction count mismatch: %',v_count; end if;
 v_result:=public.import_legacy_cash_financial_records(v_business,'a0540000-0000-4000-8000-000000000055');
 if (v_result->>'unchanged')::integer<>4 then raise exception 'Repeated cash import should be idempotent: %',v_result; end if;
end $$;
rollback;
