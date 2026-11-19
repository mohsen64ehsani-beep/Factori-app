-- 060: Account transfers created on web sync to Android and legacy transfers import idempotently.
begin;
do $$
declare v_user uuid:='a0600000-0000-4000-8000-000000000001';v_business uuid;v_from uuid;v_to uuid;v_chart uuid;v_transfer uuid;v_result jsonb;v_payload jsonb;
begin
 insert into auth.users(id,email,raw_user_meta_data) values(v_user,'factoori-account-transfer-bridge-ci@example.invalid','{"display_name":"Account Transfer Bridge CI"}'::jsonb) on conflict(id) do nothing;
 perform set_config('request.jwt.claim.sub',v_user::text,true);
 v_business:=public.create_business('Account Transfer Bridge CI');
 select id into v_from from public.financial_accounts where business_id=v_business and is_default limit 1;
 select chart_account_id into v_chart from public.financial_account_ledger_map where business_id=v_business and financial_account_id=v_from;
 insert into public.financial_accounts(business_id,name,account_type,legacy_id,created_by) values(v_business,'Bridge Bank 060','bank','legacy-bank-060',v_user) returning id into v_to;
 perform public.set_financial_account_ledger_map(v_business,v_to,v_chart);
 v_transfer:=public.post_account_transfer(v_business,v_from,v_to,6000,current_date,'Web transfer','web-transfer-060',null);
 select payload_public into v_payload from private.business_state_records where business_id=v_business and collection='moneytransfers' and legacy_id=v_transfer::text;
 if v_payload is null or v_payload->>'fromAccount' is null or v_payload->>'toAccount'<>'legacy-bank-060' then raise exception 'Web account transfer was not mirrored to Android'; end if;
 insert into private.business_state_records(business_id,collection,legacy_id,payload_public,updated_by)
 values(v_business,'moneytransfers','legacy-transfer-060',jsonb_build_object('id','legacy-transfer-060','dt',current_date::text,'fromAccount',(select legacy_id from public.financial_accounts where id=v_from),'toAccount','legacy-bank-060','amount',7000,'note','Legacy transfer'),v_user);
 v_result:=public.import_legacy_account_transfers(v_business,gen_random_uuid());
 if (v_result->>'imported')::integer<>1 then raise exception 'Legacy account transfer did not import: %',v_result; end if;
 v_result:=public.import_legacy_account_transfers(v_business,gen_random_uuid());
 if (v_result->>'unchanged')::integer<>1 then raise exception 'Legacy account transfer import is not idempotent: %',v_result; end if;
end $$;
rollback;
