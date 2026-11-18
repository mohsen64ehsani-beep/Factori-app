-- 041: Web-created goods-sale drafts are mirrored into the Android invoice sync stream.
begin;
do $$
declare
 v_user uuid:='a0410000-0000-4000-8000-000000000001'; v_business uuid; v_contact uuid; v_product uuid; v_document uuid;
 v_payload jsonb;
begin
 insert into auth.users(id,email,raw_user_meta_data) values(v_user,'factoori-invoice-bridge-ci@example.invalid','{"display_name":"Invoice Bridge CI"}'::jsonb) on conflict(id) do nothing;
 perform set_config('request.jwt.claim.sub',v_user::text,true);
 v_business:=public.create_business('Invoice Bridge CI');
 v_contact:=public.web_create_contact(v_business,'customer','Invoice Customer 041',null,null,null,null);
 v_product:=public.web_create_product(v_business,'Invoice Product 041','INV041','عدد',4100,true,0,null);
 v_document:=public.create_document_draft(v_business,'goods_sale',v_contact,null,null,current_date,null,'bridge test',0,0,
  jsonb_build_array(jsonb_build_object('item_type','goods','product_id',v_product,'description','Invoice Product 041','quantity',2,'unit_name','عدد','unit_price',4100,'discount_amount',0,'tax_rate',0)),
  'invoice-bridge-ci-041');
 select payload_public into v_payload from private.business_state_records where business_id=v_business and collection='inv' and legacy_id=v_document::text;
 if v_payload is null or v_payload->>'id'<>v_document::text then raise exception 'Web invoice draft was not mirrored to mobile sync'; end if;
 if coalesce(v_payload->>'no','') !~ '^[0-9]+$' then raise exception 'Web invoice did not receive a mobile-compatible number'; end if;
 if jsonb_array_length(coalesce(v_payload->'items','[]'::jsonb))<>1 then raise exception 'Mobile invoice line items were not mirrored'; end if;
 if v_payload #> '{items,0,b}' is not null then raise exception 'Sensitive unit cost leaked into the public mobile invoice payload'; end if;
 if not exists(select 1 from public.record_revisions rr join private.business_state_records r on r.id=rr.record_id where rr.business_id=v_business and rr.record_type='inv' and r.legacy_id=v_document::text) then raise exception 'Invoice revision was not published to the sync cursor'; end if;
 if jsonb_array_length(public.web_list_legacy_invoices(v_business))<>1 then raise exception 'Web invoice list RPC did not return mirrored invoice'; end if;
 insert into private.business_state_records(business_id,collection,legacy_id,payload_public,updated_by)
 values(v_business,'inv','mobile-invoice-041','{"id":"mobile-invoice-041","no":41,"dt":"2026-11-18","cid":"legacy-contact","items":[{"pid":"legacy-product","n":"Mobile Invoice Item","q":1,"p":4100}],"ds":0,"tx":0}'::jsonb,v_user);
 if jsonb_array_length(public.web_list_legacy_invoices(v_business))<>2 then raise exception 'Android-origin invoice record is not visible in web list RPC'; end if;
end $$;
rollback;
