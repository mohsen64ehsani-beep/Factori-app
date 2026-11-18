-- 008: Transactional posting RPCs for balanced journals and warehouse transfers.
-- DEVELOPMENT DRAFT ONLY. Depends on 001-007. Never apply to production without release approval.
begin;

create or replace function public.post_journal_entry(
 p_business_id uuid,
 p_entry_date date,
 p_description text,
 p_fiscal_period_id uuid,
 p_lines jsonb,
 p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
 v_user uuid:=auth.uid();
 v_entry_id uuid;
 v_line jsonb;
 v_account_id uuid;
 v_contact_id uuid;
 v_debit numeric(20,0);
 v_credit numeric(20,0);
 v_debit_total numeric(30,0):=0;
 v_credit_total numeric(30,0):=0;
 v_line_count integer:=0;
 v_fingerprint text;
 v_existing_fingerprint text;
 v_existing_id uuid;
 v_period record;
 v_canonical_lines jsonb:='[]'::jsonb;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required'; end if;
 if not private.has_business_permission(p_business_id,'accounting.journal.post') then
  raise exception using errcode='42501',message='Journal posting is not permitted';
 end if;
 if p_entry_date is null or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 160 then
  raise exception using errcode='22023',message='Entry date and valid idempotency key are required';
 end if;
 if p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines) not between 2 and 200 then
  raise exception using errcode='22023',message='Journal entry must contain between 2 and 200 lines';
 end if;
 if p_fiscal_period_id is not null then
  select status,date_from,date_to into v_period from public.fiscal_periods
  where business_id=p_business_id and id=p_fiscal_period_id for share;
  if not found or v_period.status<>'open' or p_entry_date not between v_period.date_from and v_period.date_to then
   raise exception using errcode='22023',message='Fiscal period is closed or date is outside the period';
  end if;
 end if;

 -- Idempotency is checked after validating and normalizing the submitted lines.
 for v_line in select value from jsonb_array_elements(p_lines) loop
  if jsonb_typeof(v_line)<>'object' then raise exception using errcode='22023',message='Journal line must be an object'; end if;
  v_account_id:=nullif(v_line->>'account_id','')::uuid;
  v_contact_id:=nullif(v_line->>'contact_id','')::uuid;
  v_debit:=coalesce((v_line->>'debit')::numeric,0);
  v_credit:=coalesce((v_line->>'credit')::numeric,0);
  if v_account_id is null or v_debit<0 or v_credit<0
    or not ((v_debit>0 and v_credit=0) or (v_credit>0 and v_debit=0)) then
   raise exception using errcode='22023',message='Each journal line must have one positive debit or credit';
  end if;
  if not exists(select 1 from public.chart_of_accounts a where a.business_id=p_business_id
    and a.id=v_account_id and a.is_active and a.allow_posting) then
   raise exception using errcode='22023',message='Journal account is missing, inactive or non-posting';
  end if;
  if v_contact_id is not null and not exists(select 1 from public.contacts c
    where c.business_id=p_business_id and c.id=v_contact_id and c.is_active) then
   raise exception using errcode='22023',message='Journal contact is missing or inactive';
  end if;
  v_debit_total:=v_debit_total+v_debit;
  v_credit_total:=v_credit_total+v_credit;
  v_line_count:=v_line_count+1;
  v_canonical_lines:=v_canonical_lines||jsonb_build_array(jsonb_build_object(
    'account_id',v_account_id,'contact_id',v_contact_id,'debit',v_debit,'credit',v_credit,
    'description',nullif(btrim(coalesce(v_line->>'description','')),'')));
 end loop;
 if v_line_count<2 or v_debit_total<=0 or v_debit_total<>v_credit_total then
  raise exception using errcode='23514',message='Journal entry is not balanced';
 end if;

 v_fingerprint:=md5(jsonb_build_array(p_business_id,p_entry_date,nullif(btrim(coalesce(p_description,'')),''),p_fiscal_period_id,v_canonical_lines)::text);
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text||':journal:'||p_idempotency_key,0));
 select je.id,md5(jsonb_build_array(je.business_id,je.entry_date,nullif(btrim(coalesce(je.description,'')),''),je.fiscal_period_id,
   coalesce((select jsonb_agg(jsonb_build_object('account_id',jl.account_id,'contact_id',jl.contact_id,
     'debit',jl.debit,'credit',jl.credit,'description',jl.description) order by jl.line_order)
     from public.journal_lines jl where jl.business_id=je.business_id and jl.journal_entry_id=je.id),'[]'::jsonb)))
 into v_existing_id,v_existing_fingerprint
 from public.journal_entries je
 where je.business_id=p_business_id and je.idempotency_key=p_idempotency_key;
 if v_existing_id is not null then
  if v_existing_fingerprint is distinct from v_fingerprint then
   raise exception using errcode='23505',message='Idempotency key reused with different journal data';
  end if;
  return v_existing_id;
 end if;

 insert into public.journal_entries(business_id,entry_date,fiscal_period_id,source_type,description,
   status,idempotency_key,created_by)
 values(p_business_id,p_entry_date,p_fiscal_period_id,'manual',nullif(btrim(coalesce(p_description,'')),''),
   'draft',p_idempotency_key,v_user)
 returning id into v_entry_id;

 v_line_count:=0;
 for v_line in select value from jsonb_array_elements(p_lines) loop
  v_line_count:=v_line_count+1;
  insert into public.journal_lines(business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order)
  values(p_business_id,v_entry_id,(v_line->>'account_id')::uuid,nullif(v_line->>'contact_id','')::uuid,
    coalesce((v_line->>'debit')::numeric,0),coalesce((v_line->>'credit')::numeric,0),
    nullif(btrim(coalesce(v_line->>'description','')),''),v_line_count);
 end loop;

 update public.journal_entries set status='posted',posted_at=now(),posted_by=v_user,version=version+1
 where business_id=p_business_id and id=v_entry_id;
 return v_entry_id;
end;
$$;

create or replace function public.post_stock_transfer(
 p_business_id uuid,
 p_from_warehouse_id uuid,
 p_to_warehouse_id uuid,
 p_transfer_date date,
 p_note text,
 p_items jsonb,
 p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
 v_user uuid:=auth.uid();
 v_transfer_id uuid;
 v_item jsonb;
 v_product_id uuid;
 v_qty numeric(20,4);
 v_available numeric(20,4);
 v_line integer:=0;
 v_fingerprint text;
 v_existing_fingerprint text;
 v_existing_id uuid;
 v_item_count integer;
 v_canonical_items jsonb:='[]'::jsonb;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required'; end if;
 if not private.has_business_permission(p_business_id,'inventory.adjust') then
  raise exception using errcode='42501',message='Inventory transfer is not permitted';
 end if;
 if p_from_warehouse_id is null or p_to_warehouse_id is null or p_from_warehouse_id=p_to_warehouse_id
   or p_transfer_date is null or p_idempotency_key is null
   or length(p_idempotency_key) not between 8 and 160 then
  raise exception using errcode='22023',message='Invalid transfer header or idempotency key';
 end if;
 if not exists(select 1 from public.warehouses w where w.business_id=p_business_id and w.id=p_from_warehouse_id and w.is_active)
   or not exists(select 1 from public.warehouses w where w.business_id=p_business_id and w.id=p_to_warehouse_id and w.is_active) then
  raise exception using errcode='22023',message='Source or destination warehouse is missing or inactive';
 end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 100 then
  raise exception using errcode='22023',message='Transfer must contain between 1 and 100 items';
 end if;
 if exists(select 1 from jsonb_array_elements(p_items) e
   group by nullif(e.value->>'product_id','')::uuid having count(*)>1) then
  raise exception using errcode='22023',message='Duplicate products must be combined into one transfer line';
 end if;
 -- Canonicalize the transfer lines before checking the idempotency key.
 for v_item in select value from jsonb_array_elements(p_items) loop
  if jsonb_typeof(v_item)<>'object' then raise exception using errcode='22023',message='Transfer line must be an object'; end if;
  v_product_id:=nullif(v_item->>'product_id','')::uuid;
  v_qty:=coalesce((v_item->>'quantity')::numeric,0);
  if v_product_id is null or v_qty<=0 or v_qty>1000000000 then
   raise exception using errcode='22023',message='Invalid transfer product or quantity';
  end if;
  v_canonical_items:=v_canonical_items||jsonb_build_array(jsonb_build_object('product_id',v_product_id,'quantity',v_qty));
 end loop;
 v_fingerprint:=md5(jsonb_build_array(p_business_id,p_from_warehouse_id,p_to_warehouse_id,p_transfer_date,
   nullif(btrim(coalesce(p_note,'')),''),v_canonical_items)::text);
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text||':transfer:'||p_idempotency_key,0));
 select st.id,md5(jsonb_build_array(st.business_id,st.from_warehouse_id,st.to_warehouse_id,st.transfer_date,
   nullif(btrim(coalesce(st.note,'')),''),coalesce((select jsonb_agg(jsonb_build_object('product_id',si.product_id,'quantity',si.quantity) order by si.line_order)
     from public.stock_transfer_items si where si.business_id=st.business_id and si.transfer_id=st.id),'[]'::jsonb)))
 into v_existing_id,v_existing_fingerprint
 from public.stock_transfers st
 where st.business_id=p_business_id and st.idempotency_key=p_idempotency_key;
 if v_existing_id is not null then
  if v_existing_fingerprint is distinct from v_fingerprint then
   raise exception using errcode='23505',message='Idempotency key reused with different transfer data';
  end if;
  return v_existing_id;
 end if;

 -- Serialize stock changes per product, in stable order, before checking availability.
 for v_product_id in
  select (e.value->>'product_id')::uuid
  from jsonb_array_elements(p_items) e
  order by (e.value->>'product_id')::uuid
 loop
  perform 1 from public.products p where p.business_id=p_business_id and p.id=v_product_id and p.is_active and p.track_inventory for update;
  if not found then raise exception using errcode='22023',message='Transfer product is missing, inactive or does not track inventory'; end if;
 end loop;

 for v_item in select value from jsonb_array_elements(p_items) loop
  v_product_id:=nullif(v_item->>'product_id','')::uuid;
  v_qty:=coalesce((v_item->>'quantity')::numeric,0);
  if v_product_id is null or v_qty<=0 or v_qty>1000000000 then
   raise exception using errcode='22023',message='Invalid transfer product or quantity';
  end if;
  select coalesce(sum(sm.quantity_delta),0) into v_available
  from public.stock_movements sm
  where sm.business_id=p_business_id and sm.product_id=v_product_id and sm.warehouse_id=p_from_warehouse_id;
  if v_available<v_qty then raise exception using errcode='23514',message='Insufficient stock in source warehouse'; end if;
 end loop;

 insert into public.stock_transfers(business_id,from_warehouse_id,to_warehouse_id,transfer_date,status,note,idempotency_key,created_by)
 values(p_business_id,p_from_warehouse_id,p_to_warehouse_id,p_transfer_date,'draft',nullif(btrim(coalesce(p_note,'')),''),p_idempotency_key,v_user)
 returning id into v_transfer_id;

 for v_item in select value from jsonb_array_elements(p_items) loop
  v_line:=v_line+1;
  v_product_id:=(v_item->>'product_id')::uuid;
  v_qty:=(v_item->>'quantity')::numeric;
  insert into public.stock_transfer_items(business_id,transfer_id,product_id,quantity,line_order)
  values(p_business_id,v_transfer_id,v_product_id,v_qty,v_line);
  insert into public.stock_movements(business_id,product_id,warehouse_id,movement_type,quantity_delta,
    movement_date,transfer_id,idempotency_key,note,created_by)
  values
   (p_business_id,v_product_id,p_from_warehouse_id,'transfer_out',-v_qty,p_transfer_date::timestamptz,
    v_transfer_id,v_transfer_id::text||':'||v_line||':out',nullif(btrim(coalesce(p_note,'')),''),v_user),
   (p_business_id,v_product_id,p_to_warehouse_id,'transfer_in',v_qty,p_transfer_date::timestamptz,
    v_transfer_id,v_transfer_id::text||':'||v_line||':in',nullif(btrim(coalesce(p_note,'')),''),v_user);
 end loop;
 update public.stock_transfers set status='posted',version=version+1,updated_at=now()
 where business_id=p_business_id and id=v_transfer_id;
 return v_transfer_id;
end;
$$;

revoke all on function public.post_journal_entry(uuid,date,text,uuid,jsonb,text) from public,anon;
revoke all on function public.post_stock_transfer(uuid,uuid,uuid,date,text,jsonb,text) from public,anon;
grant execute on function public.post_journal_entry(uuid,date,text,uuid,jsonb,text) to authenticated;
grant execute on function public.post_stock_transfer(uuid,uuid,uuid,date,text,jsonb,text) to authenticated;

commit;
