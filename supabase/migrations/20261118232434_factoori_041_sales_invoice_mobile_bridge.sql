begin;
create table if not exists private.business_document_sequences(
 business_id uuid primary key references public.businesses(id) on delete cascade,
 last_number bigint not null default 0 check(last_number>=0),
 updated_at timestamptz not null default now()
);
alter table private.business_document_sequences enable row level security;
revoke all on private.business_document_sequences from public,anon,authenticated;
create or replace function private.assign_sales_document_number()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_number bigint; v_existing_max bigint;
begin
 if new.document_type<>'goods_sale' or new.document_number is not null then return new; end if;
 select coalesce(max(document_number::bigint),0) into v_existing_max from public.documents
 where business_id=new.business_id and document_number ~ '^[0-9]+$';
 insert into private.business_document_sequences(business_id,last_number,updated_at) values(new.business_id,v_existing_max+1,now())
 on conflict(business_id) do update set last_number=greatest(private.business_document_sequences.last_number+1,v_existing_max+1),updated_at=now()
 returning last_number into v_number;
 new.document_number:=v_number::text; return new;
end;
$$;
drop trigger if exists documents_assign_sales_number on public.documents;
create trigger documents_assign_sales_number before insert on public.documents for each row execute function private.assign_sales_document_number();

create or replace function private.write_legacy_master_record(p_business_id uuid,p_collection text,p_legacy_id text,p_payload jsonb,p_deleted boolean,p_actor uuid)
returns void language plpgsql security definer set search_path='' as $$
declare
 v_record_id uuid; v_version bigint; v_existing_payload jsonb; v_existing_private jsonb; v_deleted_at timestamptz;
 v_revision bigint; v_change_type text; v_public jsonb; v_private jsonb; v_cost_allowed boolean;
begin
 if p_collection not in ('cust','suppliers','prod','inv') or p_legacy_id is null or length(btrim(p_legacy_id)) not between 1 and 200 then raise exception using errcode='22023',message='Invalid legacy master record identity'; end if;
 if not p_deleted and (p_payload is null or jsonb_typeof(p_payload)<>'object' or coalesce(p_payload->>'id','')<>p_legacy_id) then raise exception using errcode='22023',message='Invalid legacy master record payload'; end if;
 v_public:=private.strip_sensitive_json(coalesce(p_payload,'{}'::jsonb));
 v_private:=private.extract_sensitive_json(coalesce(p_payload,'{}'::jsonb));
 v_cost_allowed:=coalesce(p_actor is not null and private.has_business_permission(p_business_id,'catalog.cost.read'),false);
 if not v_cost_allowed then v_private:='{}'::jsonb; end if;
 if p_deleted then
  update private.business_state_records set deleted_at=now(),version=version+1,updated_at=now(),updated_by=p_actor
  where business_id=p_business_id and collection=p_collection and legacy_id=p_legacy_id and deleted_at is null
  returning id,version into v_record_id,v_version;
  if not found then return; end if;
  v_change_type:='delete';
 else
  select id,version,payload_public,payload_private,deleted_at into v_record_id,v_version,v_existing_payload,v_existing_private,v_deleted_at
  from private.business_state_records where business_id=p_business_id and collection=p_collection and legacy_id=p_legacy_id for update;
  if found then
   if v_existing_payload=v_public and v_deleted_at is null and (not v_cost_allowed or v_existing_private=v_private) then return; end if;
   if not v_cost_allowed then v_private:=coalesce(v_existing_private,'{}'::jsonb); end if;
   update private.business_state_records set payload_public=v_public,payload_private=v_private,version=v_version+1,updated_at=now(),updated_by=p_actor,deleted_at=null
   where business_id=p_business_id and id=v_record_id returning version into v_version;
  else
   insert into private.business_state_records(business_id,collection,legacy_id,payload_public,payload_private,version,created_at,updated_at,updated_by)
   values(p_business_id,p_collection,p_legacy_id,v_public,v_private,1,now(),now(),p_actor) returning id,version into v_record_id,v_version;
  end if;
  v_change_type:='upsert';
 end if;
 insert into private.business_sync_counters(business_id,last_revision,updated_at) values(p_business_id,1,now())
 on conflict(business_id) do update set last_revision=private.business_sync_counters.last_revision+1,updated_at=now()
 returning last_revision into v_revision;
 insert into public.record_revisions(business_id,record_type,record_id,revision,changed_by,change_type,change_payload)
 values(p_business_id,p_collection,v_record_id,v_revision,p_actor,v_change_type,jsonb_build_object('legacy_id',p_legacy_id,'version',v_version));
end;
$$;

create or replace function private.publish_sales_document_to_legacy()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_contact_legacy text; v_warehouse_legacy text; v_items jsonb; v_payload jsonb; v_actor uuid; v_tax_rate numeric:=0; v_cost_allowed boolean;
begin
 if pg_trigger_depth()>1 or new.document_type<>'goods_sale' then return new; end if;
 if not exists(select 1 from public.document_items i where i.business_id=new.business_id and i.document_id=new.id) then return new; end if;
 select c.legacy_id into v_contact_legacy from public.contacts c where c.business_id=new.business_id and c.id=new.contact_id;
 select w.legacy_id into v_warehouse_legacy from public.warehouses w where w.business_id=new.business_id and w.id=new.warehouse_id;
 select coalesce(max(i.tax_rate_snapshot),0) into v_tax_rate from public.document_items i where i.business_id=new.business_id and i.document_id=new.id;
 v_cost_allowed:=private.has_business_permission(new.business_id,'catalog.cost.read');
 select coalesce(jsonb_agg(jsonb_build_object('pid',coalesce(p.legacy_id,i.product_id::text),'n',i.description_snapshot,'q',i.quantity,'p',i.unit_price,'b',case when v_cost_allowed then coalesce(c.unit_cost_snapshot,0) else 0 end) order by i.sort_order),'[]'::jsonb)
 into v_items from public.document_items i
 left join public.products p on p.business_id=i.business_id and p.id=i.product_id
 left join public.document_item_costs c on c.business_id=i.business_id and c.document_item_id=i.id
 where i.business_id=new.business_id and i.document_id=new.id;
 v_actor:=coalesce(new.created_by,auth.uid());
 v_payload:=jsonb_build_object('id',new.id::text,'no',coalesce(nullif(new.document_number,'')::bigint,0),'dt',new.document_date::text,
 'createdAt',new.created_at::date::text,'cid',coalesce(v_contact_legacy,new.contact_id::text),
 'warehouseId',coalesce(v_warehouse_legacy,new.warehouse_id::text,''),'bankAccountId','','items',v_items,
 'ds',new.discount_amount,'tx',v_tax_rate,'status',new.status,'notes',coalesce(new.notes,''));
 perform private.write_legacy_master_record(new.business_id,'inv',new.id::text,v_payload,false,v_actor);
 return new;
end;
$$;
drop trigger if exists documents_publish_mobile_invoice on public.documents;
create trigger documents_publish_mobile_invoice after insert or update on public.documents
for each row when (new.document_type='goods_sale') execute function private.publish_sales_document_to_legacy();

create or replace function public.web_list_legacy_invoices(p_business_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_cost_allowed boolean;
begin
 if auth.uid() is null or not private.has_business_permission(p_business_id,'sales.read') then raise exception using errcode='42501',message='Sales read permission denied'; end if;
 v_cost_allowed:=private.has_business_permission(p_business_id,'catalog.cost.read');
 return coalesce((select jsonb_agg(jsonb_build_object('legacy_id',r.legacy_id,'payload',case when v_cost_allowed then private.merge_sensitive_json(r.payload_public,r.payload_private) else r.payload_public end,'version',r.version,'updated_at',r.updated_at) order by r.updated_at desc)
 from private.business_state_records r where r.business_id=p_business_id and r.collection='inv' and r.deleted_at is null),'[]'::jsonb);
end;
$$;
revoke all on function private.assign_sales_document_number() from public,anon,authenticated;
revoke all on function private.publish_sales_document_to_legacy() from public,anon,authenticated;
revoke all on function public.web_list_legacy_invoices(uuid) from public,anon;
grant execute on function public.web_list_legacy_invoices(uuid) to authenticated;
commit;