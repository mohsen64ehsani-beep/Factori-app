-- 046: Normalized financial, cheque and stock writes are mirrored to Android sync collections.
begin;
do $$
declare
 v_user uuid:='a0460000-0000-4000-8000-000000000001';v_business uuid;v_contact uuid;v_product uuid;v_account uuid;v_warehouse uuid;v_tx uuid;v_cheque uuid;v_stock uuid;v_payload jsonb;v_import jsonb;
begin
 insert into auth.users(id,email,raw_user_meta_data) values(v_user,'factoori-web-mobile-bridge-ci@example.invalid','{"display_name":"Web Mobile Bridge CI"}'::jsonb) on conflict(id) do nothing;
 perform set_config('request.jwt.claim.sub',v_user::text,true);
 v_business:=public.create_business('Web Mobile Bridge CI');
 v_contact:=public.web_create_contact(v_business,'customer','Bridge Customer 046',null,null,null,null);
 select id into v_account from public.financial_accounts where business_id=v_business and is_active order by is_default desc limit 1;
 if v_account is null then raise exception 'Business default financial account missing'; end if;
 v_tx:=public.post_customer_receipt(v_business,v_contact,v_account,12500,current_date,null,0,'BR-046','Bridge receipt','bridge-receipt-046');
 select payload_public into v_payload from private.business_state_records where business_id=v_business and collection='pay' and legacy_id=v_tx::text;
 if v_payload is null or v_payload->>'kind'<>'cash' or (v_payload->>'amt')::numeric<>12500 then raise exception 'Customer receipt did not reach Android pay collection'; end if;
 v_cheque:=public.create_cheque(v_business,'received',v_contact,'CHQ-046',null,'بانک آزمایشی',null,null,null,null,null,25000,current_date,current_date+7,'Bridge cheque','bridge-cheque-046');
 select payload_public into v_payload from private.business_state_records where business_id=v_business and collection='pay' and legacy_id=v_cheque::text;
 if v_payload is null or v_payload->>'kind'<>'cheque' or v_payload->>'status'<>'pending' then raise exception 'Received cheque did not reach Android pay collection'; end if;
 v_product:=public.web_create_product(v_business,'Bridge Product 046','BR046','عدد',1000,true,0,null);
 insert into public.warehouses(business_id,name,is_default,is_active) values(v_business,'Bridge Warehouse 046',true,true) returning id into v_warehouse;
 insert into public.stock_movements(business_id,product_id,warehouse_id,movement_type,quantity_delta,movement_date,idempotency_key,created_by)
 values(v_business,v_product,v_warehouse,'opening',8,now(),'bridge-stock-046',v_user) returning id into v_stock;
 select payload_public into v_payload from private.business_state_records where business_id=v_business and collection='stockMoves' and legacy_id=v_stock::text;
 if v_payload is null or (v_payload->>'after')::numeric<>8 then raise exception 'Stock movement did not reach Android sync collection'; end if;
 select payload_public into v_payload from private.business_state_records r join public.products p on p.business_id=r.business_id and p.legacy_id=r.legacy_id
 where r.business_id=v_business and r.collection='prod' and p.id=v_product;
 if v_payload is null or (v_payload->>'qty')::numeric<>8 then raise exception 'Mobile product quantity was not refreshed from normalized stock'; end if;
 v_import:=public.web_import_legacy_supported_data(v_business,gen_random_uuid());
 if coalesce((v_import->>'imported')::boolean,false) is not true then raise exception 'Supported legacy import wrapper did not complete: %',v_import; end if;
end $$;
rollback;
