-- 039: Web master-data RPCs publish into the Android sync stream; mobile sync writes project into normalized tables.
begin;
do $$
declare
 v_user uuid:='a0390000-0000-4000-8000-000000000001';
 v_business uuid;
 v_contact uuid;
 v_product uuid;
 v_legacy_contact text:='mobile-contact-039';
 v_legacy_product text:='mobile-product-039';
begin
 insert into auth.users(id,email,raw_user_meta_data)
 values(v_user,'factoori-bridge-ci@example.invalid','{"display_name":"Bridge CI"}'::jsonb)
 on conflict(id) do nothing;
 perform set_config('request.jwt.claim.sub',v_user::text,true);
 v_business:=public.create_business('Bridge CI Business');
 v_contact:=public.web_create_contact(v_business,'customer','Web Contact 039','09120000039','C039','Web address',null);
 v_product:=public.web_create_product(v_business,'Web Product 039','SKU039','عدد',3900,true,2,'390039');
 if not exists(select 1 from private.business_state_records where business_id=v_business and collection='cust' and legacy_id=(select legacy_id from public.contacts where id=v_contact)) then
  raise exception 'Web contact was not published to the mobile sync stream';
 end if;
 if not exists(select 1 from private.business_state_records where business_id=v_business and collection='prod' and legacy_id=(select legacy_id from public.products where id=v_product)) then
  raise exception 'Web product was not published to the mobile sync stream';
 end if;
 insert into private.business_state_records(business_id,collection,legacy_id,payload_public,updated_by)
 values
 (v_business,'cust',v_legacy_contact,'{"id":"mobile-contact-039","n":"Mobile Contact 039","ph":"09121111139","ad":"Mobile address"}'::jsonb,v_user),
 (v_business,'prod',v_legacy_product,'{"id":"mobile-product-039","n":"Mobile Product 039","sell":3900,"minQty":4,"barcode":"390039"}'::jsonb,v_user);
 if not exists(select 1 from public.contacts where business_id=v_business and legacy_id=v_legacy_contact and name='Mobile Contact 039') then
  raise exception 'Mobile customer record was not projected into normalized contacts';
 end if;
 if not exists(select 1 from public.products where business_id=v_business and legacy_id=v_legacy_product and name='Mobile Product 039' and sale_price=3900) then
  raise exception 'Mobile product record was not projected into normalized products';
 end if;
 if not has_function_privilege('authenticated','public.web_create_contact(uuid,text,text,text,text,text,text)','EXECUTE')
   or not has_function_privilege('authenticated','public.web_create_product(uuid,text,text,text,numeric,boolean,numeric,text)','EXECUTE') then
  raise exception 'Web master-data RPC grants are missing';
 end if;
 if has_table_privilege('authenticated','public.contacts','INSERT')
   or has_table_privilege('authenticated','public.products','INSERT') then
  raise exception 'Direct REST inserts must remain disabled';
 end if;
end $$;
rollback;
