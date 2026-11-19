begin;
create or replace function private.assign_sales_document_number()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_number bigint;v_existing_max bigint;
begin
 if new.document_type not in ('goods_sale','service_sale') or new.document_number is not null then return new; end if;
 select coalesce(max(document_number::bigint),0) into v_existing_max from public.documents where business_id=new.business_id and document_number ~ '^[0-9]+$';
 insert into private.business_document_sequences(business_id,last_number,updated_at) values(new.business_id,v_existing_max+1,now())
 on conflict(business_id) do update set last_number=greatest(private.business_document_sequences.last_number+1,v_existing_max+1),updated_at=now()
 returning last_number into v_number;
 new.document_number:=v_number::text;return new;
end; $$;
commit;