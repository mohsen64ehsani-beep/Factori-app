-- 023: Atomic wastage posting with FIFO cost consumption and inventory write-off.
-- DEVELOPMENT DRAFT ONLY.
begin;

create table if not exists public.inventory_wastage_batches (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 wastage_date date not null,
 status text not null default 'posted' check(status in ('posted')),
 reason text,
 idempotency_key text not null,
 request_fingerprint text not null,
 journal_entry_id uuid,
 total_cost numeric(30,0) not null default 0 check(total_cost>=0),
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 unique(business_id,id),
 unique(business_id,idempotency_key),
 unique(business_id,journal_entry_id),
 foreign key(business_id,journal_entry_id) references public.journal_entries(business_id,id)
);
create table if not exists public.inventory_wastage_items (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null,
 batch_id uuid not null,
 product_id uuid not null,
 warehouse_id uuid not null,
 stock_movement_id uuid not null,
 quantity numeric(20,4) not null check(quantity>0),
 total_cost numeric(30,0) not null check(total_cost>=0),
 line_order integer not null,
 unique(business_id,id),
 unique(business_id,stock_movement_id),
 foreign key(business_id,batch_id) references public.inventory_wastage_batches(business_id,id) on delete cascade,
 foreign key(business_id,product_id) references public.products(business_id,id),
 foreign key(business_id,warehouse_id) references public.warehouses(business_id,id),
 foreign key(business_id,stock_movement_id) references public.stock_movements(business_id,id)
);
alter table public.inventory_wastage_batches enable row level security;
alter table public.inventory_wastage_items enable row level security;
revoke all on public.inventory_wastage_batches,public.inventory_wastage_items from public,anon,authenticated;

create or replace function public.post_inventory_wastage(
 p_business_id uuid,
 p_wastage_date date,
 p_reason text,
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
 v_batch_id uuid;
 v_journal_id uuid;
 v_item jsonb;
 v_product_id uuid;
 v_warehouse_id uuid;
 v_quantity numeric(20,4);
 v_remaining numeric(20,4);
 v_take numeric(20,4);
 v_available numeric(30,4);
 v_layer_available numeric(30,4);
 v_line_cost numeric(30,0);
 v_total_cost numeric(30,0):=0;
 v_line integer:=0;
 v_fingerprint text;
 v_existing_fingerprint text;
 v_existing_id uuid;
 v_canonical_items jsonb:='[]'::jsonb;
 v_movement_id uuid;
 v_expense_account_id uuid;
 v_inventory_account_id uuid;
 v_period_id uuid;
 v_layer record;
begin
 if v_user is null then
  raise exception using errcode='28000',message='Authentication required';
 end if;
 if not private.has_business_permission(p_business_id,'inventory.adjust') then
  raise exception using errcode='42501',message='Inventory wastage is not permitted';
 end if;
 if p_wastage_date is null or p_idempotency_key is null
   or length(p_idempotency_key) not between 8 and 160 then
  raise exception using errcode='22023',message='Wastage date and valid idempotency key are required';
 end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 500 then
  raise exception using errcode='22023',message='Wastage batch must contain between 1 and 500 lines';
 end if;
 if exists(
  select 1 from jsonb_array_elements(p_items) e
  group by nullif(e.value->>'product_id','')::uuid,nullif(e.value->>'warehouse_id','')::uuid
  having count(*)>1
 ) then
  raise exception using errcode='22023',message='Duplicate product and warehouse lines must be combined';
 end if;
 for v_item in select value from jsonb_array_elements(p_items) loop
  if jsonb_typeof(v_item)<>'object' then
   raise exception using errcode='22023',message='Wastage line must be an object';
  end if;
  v_product_id:=nullif(v_item->>'product_id','')::uuid;
  v_warehouse_id:=nullif(v_item->>'warehouse_id','')::uuid;
  v_quantity:=coalesce((v_item->>'quantity')::numeric,0);
  if v_product_id is null or v_warehouse_id is null
    or v_quantity::text in ('NaN','Infinity','-Infinity')
    or v_quantity<=0 or v_quantity>1000000000 or round(v_quantity,4)<>v_quantity then
   raise exception using errcode='22023',message='Wastage quantity or references are invalid';
  end if;
  v_canonical_items:=v_canonical_items||jsonb_build_array(jsonb_build_object(
   'product_id',v_product_id,'warehouse_id',v_warehouse_id,'quantity',v_quantity::numeric(20,4)
  ));
 end loop;
 v_fingerprint:=md5(jsonb_build_array(p_business_id,p_wastage_date,
  nullif(btrim(coalesce(p_reason,'')),''),v_canonical_items)::text);
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text||':inventory-wastage:'||p_idempotency_key,0));
 select b.id,b.request_fingerprint into v_existing_id,v_existing_fingerprint
 from public.inventory_wastage_batches b
 where b.business_id=p_business_id and b.idempotency_key=p_idempotency_key;
 if v_existing_id is not null then
  if v_existing_fingerprint is distinct from v_fingerprint then
   raise exception using errcode='23505',message='Wastage idempotency key was reused with different data';
  end if;
  return v_existing_id;
 end if;

 for v_product_id in
  select distinct (e.value->>'product_id')::uuid
  from jsonb_array_elements(p_items) e order by (e.value->>'product_id')::uuid
 loop
  perform 1 from public.products p
  where p.business_id=p_business_id and p.id=v_product_id and p.is_active and p.track_inventory
  for update;
  if not found then
   raise exception using errcode='22023',message='Wastage product is missing, inactive or does not track inventory';
  end if;
 end loop;
 for v_warehouse_id in
  select distinct (e.value->>'warehouse_id')::uuid
  from jsonb_array_elements(p_items) e order by (e.value->>'warehouse_id')::uuid
 loop
  perform 1 from public.warehouses w
  where w.business_id=p_business_id and w.id=v_warehouse_id and w.is_active
  for update;
  if not found then
   raise exception using errcode='22023',message='Wastage warehouse is missing or inactive';
  end if;
 end loop;

 -- Preflight every line before inserting any movement.
 for v_item in select value from jsonb_array_elements(p_items) loop
  v_product_id:=(v_item->>'product_id')::uuid;
  v_warehouse_id:=(v_item->>'warehouse_id')::uuid;
  v_quantity:=(v_item->>'quantity')::numeric;
  select coalesce(sum(sm.quantity_delta),0) into v_available
  from public.stock_movements sm
  where sm.business_id=p_business_id and sm.product_id=v_product_id and sm.warehouse_id=v_warehouse_id;
  select coalesce(sum(l.quantity_remaining),0) into v_layer_available
  from public.inventory_cost_layers l
  where l.business_id=p_business_id and l.product_id=v_product_id
    and l.warehouse_id=v_warehouse_id and l.quantity_remaining>0;
  if v_available<v_quantity or v_layer_available<v_quantity then
   raise exception using errcode='23514',message='Insufficient reconciled stock or FIFO layers for wastage';
  end if;
 end loop;

 select fp.id into v_period_id from public.fiscal_periods fp
 where fp.business_id=p_business_id and p_wastage_date between fp.date_from and fp.date_to
 order by fp.date_from desc limit 1;
 if v_period_id is not null and not exists(
  select 1 from public.fiscal_periods fp
  where fp.business_id=p_business_id and fp.id=v_period_id and fp.status in ('open','reopened')
 ) then
  raise exception using errcode='55000',message='Wastage date belongs to a closed fiscal period';
 end if;

 insert into public.inventory_wastage_batches(
  business_id,wastage_date,status,reason,idempotency_key,request_fingerprint,created_by
 ) values (
  p_business_id,p_wastage_date,'posted',nullif(btrim(coalesce(p_reason,'')), ''),
  p_idempotency_key,v_fingerprint,v_user
 ) returning id into v_batch_id;

 for v_item in select value from jsonb_array_elements(p_items) loop
  v_line:=v_line+1;
  v_product_id:=(v_item->>'product_id')::uuid;
  v_warehouse_id:=(v_item->>'warehouse_id')::uuid;
  v_quantity:=(v_item->>'quantity')::numeric(20,4);
  insert into public.stock_movements(
   business_id,product_id,warehouse_id,movement_type,quantity_delta,movement_date,
   idempotency_key,note,created_by
  ) values (
   p_business_id,v_product_id,v_warehouse_id,'wastage',-v_quantity,
   p_wastage_date::timestamptz,
   'wastage:'||v_batch_id::text||':'||v_line,
   nullif(btrim(coalesce(p_reason,'')),''),v_user
  ) returning id into v_movement_id;

  v_remaining:=v_quantity;
  v_line_cost:=0;
  for v_layer in
   select l.id,l.quantity_remaining,l.unit_cost
   from public.inventory_cost_layers l
   where l.business_id=p_business_id and l.product_id=v_product_id
     and l.warehouse_id=v_warehouse_id and l.quantity_remaining>0
   order by l.acquired_at,l.id
   for update
  loop
   exit when v_remaining<=0;
   v_take:=least(v_remaining,v_layer.quantity_remaining);
   v_line_cost:=v_line_cost+round(v_take*v_layer.unit_cost);
   update public.inventory_cost_layers
   set quantity_remaining=quantity_remaining-v_take
   where business_id=p_business_id and id=v_layer.id;
   insert into public.inventory_cost_allocations(
    business_id,layer_id,stock_movement_id,quantity,unit_cost,total_cost
   ) values (
    p_business_id,v_layer.id,v_movement_id,v_take,v_layer.unit_cost,round(v_take*v_layer.unit_cost)
   );
   v_remaining:=v_remaining-v_take;
  end loop;
  if v_remaining>0 then
   raise exception using errcode='23514',message='FIFO layers changed during wastage posting';
  end if;
  v_total_cost:=v_total_cost+v_line_cost;
  insert into public.inventory_wastage_items(
   business_id,batch_id,product_id,warehouse_id,stock_movement_id,quantity,total_cost,line_order
  ) values (
   p_business_id,v_batch_id,v_product_id,v_warehouse_id,v_movement_id,v_quantity,v_line_cost,v_line
  );
 end loop;

 if v_total_cost>0 then
  select id into v_expense_account_id from public.chart_of_accounts
  where business_id=p_business_id and code='6000' and account_class='expense' and is_active and allow_posting;
  select id into v_inventory_account_id from public.chart_of_accounts
  where business_id=p_business_id and code='1200' and account_class='asset' and is_active and allow_posting;
  if v_expense_account_id is null or v_inventory_account_id is null then
   raise exception using errcode='55000',message='Wastage expense or inventory account is not configured';
  end if;
  insert into public.journal_entries(
   business_id,entry_date,fiscal_period_id,source_type,source_id,description,status,idempotency_key,created_by
  ) values (
   p_business_id,p_wastage_date,v_period_id,'manual',v_batch_id,
   coalesce(nullif(btrim(coalesce(p_reason,'')),''),'ثبت ضایعات کالا'),
   'draft','inventory-wastage:'||p_idempotency_key,v_user
  ) returning id into v_journal_id;
  insert into public.journal_lines(
   business_id,journal_entry_id,account_id,debit,credit,description,line_order
  ) values
   (p_business_id,v_journal_id,v_expense_account_id,v_total_cost,0,'هزینه ضایعات کالا',1),
   (p_business_id,v_journal_id,v_inventory_account_id,0,v_total_cost,'کاهش موجودی بر اثر ضایعات',2);
  update public.journal_entries
  set status='posted',posted_at=now(),posted_by=v_user,version=version+1
  where business_id=p_business_id and id=v_journal_id;
 end if;
 update public.inventory_wastage_batches
 set journal_entry_id=v_journal_id,total_cost=v_total_cost
 where business_id=p_business_id and id=v_batch_id;
 return v_batch_id;
end;
$$;

revoke all on function public.post_inventory_wastage(uuid,date,text,jsonb,text) from public,anon;
grant execute on function public.post_inventory_wastage(uuid,date,text,jsonb,text) to authenticated;

commit;
