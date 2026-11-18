begin;
create or replace function private.write_legacy_master_record(p_business_id uuid,p_collection text,p_legacy_id text,p_payload jsonb,p_deleted boolean,p_actor uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_record_id uuid;v_version bigint;v_existing_payload jsonb;v_existing_private jsonb;v_deleted_at timestamptz;v_revision bigint;v_change_type text;v_public jsonb;v_private jsonb;v_cost_allowed boolean;v_identity_valid boolean;
begin
 if p_collection not in ('cust','suppliers','prod','inv','pay','creditorPayments','expenses','purchases','supplierPayments','returns','wastage','stockMoves','warehouseStocks','transfers','accounts','moneytransfers','opening','otherincome','serviceInv','duedates','fiscal','warehouses','services','categories','smsHistory')
  or p_legacy_id is null or length(btrim(p_legacy_id)) not between 1 and 200 then raise exception using errcode='22023',message='Invalid legacy master record identity'; end if;
 if p_collection in ('services','categories') then
  v_identity_valid:=jsonb_typeof(p_payload)='object' and coalesce(p_payload->>'value','')<>'' and p_legacy_id='value:'||p_payload->>'value';
 else
  v_identity_valid:=jsonb_typeof(p_payload)='object' and coalesce(p_payload->>'id','')=p_legacy_id;
 end if;
 if not p_deleted and not coalesce(v_identity_valid,false) then raise exception using errcode='22023',message='Invalid legacy master record payload'; end if;
 v_public:=private.strip_sensitive_json(coalesce(p_payload,'{}'::jsonb));v_private:=private.extract_sensitive_json(coalesce(p_payload,'{}'::jsonb));
 v_cost_allowed:=coalesce(p_actor is not null and private.has_business_permission(p_business_id,'catalog.cost.read'),false);
 if not v_cost_allowed then v_private:='{}'::jsonb; end if;
 if p_deleted then
  update private.business_state_records set deleted_at=now(),version=version+1,updated_at=now(),updated_by=p_actor where business_id=p_business_id and collection=p_collection and legacy_id=p_legacy_id and deleted_at is null returning id,version into v_record_id,v_version;
  if not found then return; end if;v_change_type:='delete';
 else
  select id,version,payload_public,payload_private,deleted_at into v_record_id,v_version,v_existing_payload,v_existing_private,v_deleted_at from private.business_state_records where business_id=p_business_id and collection=p_collection and legacy_id=p_legacy_id for update;
  if found then
   if v_existing_payload=v_public and v_deleted_at is null and (not v_cost_allowed or v_existing_private=v_private) then return; end if;
   if not v_cost_allowed then v_private:=coalesce(v_existing_private,'{}'::jsonb); end if;
   update private.business_state_records set payload_public=v_public,payload_private=v_private,version=v_version+1,updated_at=now(),updated_by=p_actor,deleted_at=null where business_id=p_business_id and id=v_record_id returning version into v_version;
  else
   insert into private.business_state_records(business_id,collection,legacy_id,payload_public,payload_private,version,created_at,updated_at,updated_by) values(p_business_id,p_collection,p_legacy_id,v_public,v_private,1,now(),now(),p_actor) returning id,version into v_record_id,v_version;
  end if;v_change_type:='upsert';
 end if;
 insert into private.business_sync_counters(business_id,last_revision,updated_at) values(p_business_id,1,now()) on conflict(business_id) do update set last_revision=private.business_sync_counters.last_revision+1,updated_at=now() returning last_revision into v_revision;
 insert into public.record_revisions(business_id,record_type,record_id,revision,changed_by,change_type,change_payload) values(p_business_id,p_collection,v_record_id,v_revision,p_actor,v_change_type,jsonb_build_object('legacy_id',p_legacy_id,'version',v_version));
end; $$;

create or replace function public.web_create_service(p_business_id uuid,p_name text,p_description text default null,p_sale_price numeric default 0)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid();v_service_id uuid;v_legacy_id text;v_name text:=btrim(coalesce(p_name,''));
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required'; end if;
 if not private.has_business_permission(p_business_id,'catalog.write') then raise exception using errcode='42501',message='Service write permission denied'; end if;
 if length(v_name) not between 2 and 160 or p_sale_price is null or p_sale_price::text in ('NaN','Infinity','-Infinity') or p_sale_price<0 or trunc(p_sale_price)<>p_sale_price or p_sale_price>999999999999999999 or length(btrim(coalesce(p_description,'')))>1000 then
  raise exception using errcode='22023',message='Invalid service details';
 end if;
 v_legacy_id:='value:'||v_name;
 select id into v_service_id from public.services where business_id=p_business_id and lower(name)=lower(v_name) and is_active order by created_at limit 1 for update;
 if v_service_id is null then
  insert into public.services(business_id,name,description,sale_price,legacy_id,created_by,is_active)
  values(p_business_id,v_name,nullif(btrim(coalesce(p_description,'')),''),p_sale_price,v_legacy_id,v_user,true)
  returning id into v_service_id;
 else
  update public.services set name=v_name,description=nullif(btrim(coalesce(p_description,'')),''),sale_price=p_sale_price,legacy_id=v_legacy_id,updated_at=now(),version=version+1
  where business_id=p_business_id and id=v_service_id;
 end if;
 perform private.write_legacy_master_record(p_business_id,'services',v_legacy_id,jsonb_build_object('value',v_name),false,v_user);
 return v_service_id;
end; $$;

create or replace function private.publish_sales_document_to_legacy()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_contact_legacy text;v_items jsonb;v_payload jsonb;v_actor uuid;v_tax_rate numeric:=0;v_cost_allowed boolean;v_collection text;
begin
 if pg_trigger_depth()>1 or new.document_type not in ('goods_sale','service_sale') then return new; end if;
 if not exists(select 1 from public.document_items i where i.business_id=new.business_id and i.document_id=new.id) then return new; end if;
 select c.legacy_id into v_contact_legacy from public.contacts c where c.business_id=new.business_id and c.id=new.contact_id;
 select coalesce(max(i.tax_rate_snapshot),0) into v_tax_rate from public.document_items i where i.business_id=new.business_id and i.document_id=new.id;
 v_cost_allowed:=private.has_business_permission(new.business_id,'catalog.cost.read');
 if new.document_type='goods_sale' then
  v_collection:='inv';
  select coalesce(jsonb_agg(jsonb_build_object('pid',coalesce(p.legacy_id,i.product_id::text),'n',i.description_snapshot,'q',i.quantity,'p',i.unit_price,'b',case when v_cost_allowed then coalesce(c.unit_cost_snapshot,0) else 0 end) order by i.sort_order),'[]'::jsonb)
  into v_items from public.document_items i left join public.products p on p.business_id=i.business_id and p.id=i.product_id
  left join public.document_item_costs c on c.business_id=i.business_id and c.document_item_id=i.id
  where i.business_id=new.business_id and i.document_id=new.id;
  v_payload:=jsonb_build_object('id',new.id::text,'no',coalesce(nullif(new.document_number,'')::bigint,0),'dt',new.document_date::text,'createdAt',new.created_at::date::text,
   'cid',coalesce(v_contact_legacy,new.contact_id::text),'warehouseId','','bankAccountId','','items',v_items,'ds',new.discount_amount,'tx',v_tax_rate,'status',new.status,'notes',coalesce(new.notes,''));
 else
  v_collection:='serviceInv';
  select coalesce(jsonb_agg(jsonb_build_object('desc',i.description_snapshot,'qty',i.quantity,'price',i.unit_price,'cost',case when v_cost_allowed then coalesce(c.unit_cost_snapshot,0) else 0 end) order by i.sort_order),'[]'::jsonb)
  into v_items from public.document_items i left join public.document_item_costs c on c.business_id=i.business_id and c.document_item_id=i.id
  where i.business_id=new.business_id and i.document_id=new.id;
  v_payload:=jsonb_build_object('id',new.id::text,'no',coalesce(nullif(new.document_number,'')::bigint,0),'dt',new.document_date::text,'createdAt',new.created_at::date::text,
   'cid',coalesce(v_contact_legacy,new.contact_id::text),'bankAccountId','','items',v_items,'discount',new.discount_amount,'costMode','row','costTotal',0,'status',new.status);
 end if;
 v_actor:=coalesce(new.created_by,auth.uid());
 perform private.write_legacy_master_record(new.business_id,v_collection,new.id::text,v_payload,false,v_actor);
 return new;
end; $$;
revoke all on function public.web_create_service(uuid,text,text,numeric) from public,anon;
grant execute on function public.web_create_service(uuid,text,text,numeric) to authenticated;
commit;