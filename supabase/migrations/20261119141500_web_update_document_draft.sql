CREATE OR REPLACE FUNCTION public.web_update_document_draft(p_business_id uuid, p_document_id uuid, p_document_type text, p_contact_id uuid DEFAULT NULL::uuid, p_warehouse_id uuid DEFAULT NULL::uuid, p_fiscal_period_id uuid DEFAULT NULL::uuid, p_document_date date DEFAULT CURRENT_DATE, p_due_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_discount_amount numeric DEFAULT 0, p_tax_rate numeric DEFAULT NULL::numeric, p_items jsonb DEFAULT '[]'::jsonb, p_idempotency_key text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid:=auth.uid();
  v_doc_id uuid;
  v_existing_document public.documents%rowtype;
  v_permission text;
  v_item jsonb;
  v_qty numeric;
  v_price numeric;
  v_line_discount numeric;
  v_rate numeric;
  v_base numeric;
  v_base_total numeric:=0;
  v_subtotal numeric:=0;
  v_line_discounts numeric:=0;
  v_tax numeric:=0;
  v_allocated_header_discount numeric;
  v_tax_line numeric;
  v_total numeric;
  v_count integer:=0;
  v_item_count integer:=0;
  v_request_fingerprint text;
  v_existing_fingerprint text;
  v_allocated_total numeric:=0;
  v_header_discount numeric:=coalesce(p_discount_amount,0);
begin
  if v_user is null then raise exception using errcode='28000',message='Authentication required'; end if;
  select * into v_existing_document
  from public.documents
  where business_id=p_business_id and id=p_document_id
  for update;
  if not found then raise exception using errcode='P0002',message='Document not found'; end if;
  if v_existing_document.status<>'draft' then
    raise exception using errcode='22023',message='Only draft documents can be edited';
  end if;
  if v_existing_document.document_type is distinct from p_document_type then
    raise exception using errcode='22023',message='Document type cannot be changed while editing';
  end if;
  v_doc_id:=p_document_id;
  if p_document_type is null or p_document_type not in ('goods_sale','service_sale','purchase','service_purchase') then
    raise exception using errcode='22023',message='Unsupported document type';
  end if;
  v_permission:=case when p_document_type in ('goods_sale','service_sale') then 'sales.create' else 'purchases.create' end;
  if not private.has_business_permission(p_business_id,v_permission) then
    raise exception using errcode='42501',message='Document creation is not permitted';
  end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 100 then
    raise exception using errcode='22023',message='Document must contain between 1 and 100 items';
  end if;
  if v_header_discount<0 or v_header_discount>999999999999999999 then
    raise exception using errcode='22023',message='Invalid document discount';
  end if;
  if p_tax_rate is not null and p_tax_rate not between 0 and 100 then
    raise exception using errcode='22023',message='Invalid tax rate';
  end if;
  if p_due_date is not null and p_due_date<coalesce(p_document_date,current_date) then
    raise exception using errcode='22023',message='Due date cannot precede document date';
  end if;

  if p_contact_id is not null and not exists (
    select 1 from public.contacts c
    where c.business_id=p_business_id and c.id=p_contact_id
      and c.is_active
      and (
        (p_document_type in ('goods_sale','service_sale') and c.contact_type in ('customer','both'))
        or (p_document_type in ('purchase','service_purchase') and c.contact_type in ('supplier','both'))
      )
  ) then
    raise exception using errcode='22023',message='Contact is inactive, missing or has an incompatible role';
  end if;

  if p_fiscal_period_id is not null and not exists (
    select 1 from public.fiscal_periods fp
    where fp.business_id=p_business_id and fp.id=p_fiscal_period_id
      and fp.status='open'
      and coalesce(p_document_date,current_date) between fp.date_from and fp.date_to
  ) then
    raise exception using errcode='22023',message='Fiscal period is closed or document date is outside the period';
  end if;
  if p_idempotency_key is not null and length(p_idempotency_key) not between 8 and 160 then
    raise exception using errcode='22023',message='Invalid idempotency key';
  end if;

  v_request_fingerprint:=md5(jsonb_build_array(
    p_business_id,p_document_type,p_contact_id,p_warehouse_id,p_fiscal_period_id,
    coalesce(p_document_date,current_date),p_due_date,coalesce(p_notes,''),
    v_header_discount,coalesce(p_tax_rate::text,'null'),p_items
  )::text);

  -- Validate and total the submitted rows before inserting anything.
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_count:=v_count+1;
    if jsonb_typeof(v_item)<>'object' then raise exception using errcode='22023',message='Each item must be an object'; end if;
    v_qty:=coalesce((v_item->>'quantity')::numeric,0);
    v_price:=coalesce((v_item->>'unit_price')::numeric,0);
    v_line_discount:=coalesce((v_item->>'discount_amount')::numeric,0);
    v_rate:=coalesce(p_tax_rate,(v_item->>'tax_rate')::numeric,0);
    if v_qty<=0 or v_qty>1000000000 or v_price<0 or v_price>999999999999999999
      or v_line_discount<0 or v_line_discount>round(v_qty*v_price)
      or v_rate<0 or v_rate>100 then
      raise exception using errcode='22023',message='Invalid quantity, price, discount or tax rate';
    end if;
    if length(btrim(coalesce(v_item->>'description',''))) not between 1 and 500 then
      raise exception using errcode='22023',message='Item description is required';
    end if;
    if coalesce(v_item->>'item_type','goods') not in ('goods','service') then
      raise exception using errcode='22023',message='Invalid item type';
    end if;
    if (p_document_type in ('goods_sale','purchase') and coalesce(v_item->>'item_type','goods')<>'goods')
      or (p_document_type in ('service_sale','service_purchase') and coalesce(v_item->>'item_type','goods')<>'service') then
      raise exception using errcode='22023',message='Item type does not match document type';
    end if;
    v_base:=round(v_qty*v_price)-v_line_discount;
    v_subtotal:=v_subtotal+round(v_qty*v_price);
    v_line_discounts:=v_line_discounts+v_line_discount;
    v_base_total:=v_base_total+v_base;
  end loop;
  v_item_count:=v_count;
  if v_header_discount>v_base_total then raise exception using errcode='22023',message='Document discount exceeds taxable base'; end if;

  delete from public.document_items
  where business_id=p_business_id and document_id=v_doc_id;


  v_count:=0;
  v_allocated_total:=0;
  for v_item in select value from jsonb_array_elements(p_items) loop
    v_count:=v_count+1;
    v_qty:=(v_item->>'quantity')::numeric;
    v_price:=(v_item->>'unit_price')::numeric;
    v_line_discount:=coalesce((v_item->>'discount_amount')::numeric,0);
    v_rate:=coalesce(p_tax_rate,(v_item->>'tax_rate')::numeric,0);
    v_base:=round(v_qty*v_price)-v_line_discount;
    if v_count=v_item_count then
      v_allocated_header_discount:=v_header_discount-v_allocated_total;
    else
      v_allocated_header_discount:=case when v_base_total=0 then 0
        else floor(v_header_discount*v_base/v_base_total) end;
    end if;
    v_allocated_total:=v_allocated_total+v_allocated_header_discount;
    v_tax_line:=round(greatest(0,v_base-v_allocated_header_discount)*v_rate/100);
    v_tax:=v_tax+v_tax_line;
    insert into public.document_items(
      business_id,document_id,item_type,product_id,service_id,
      description_snapshot,quantity,unit_name_snapshot,unit_price,
      discount_amount,tax_rate_snapshot,tax_amount,line_total,sort_order
    ) values (
      p_business_id,v_doc_id,coalesce(v_item->>'item_type','goods'),
      nullif(v_item->>'product_id','')::uuid,nullif(v_item->>'service_id','')::uuid,
      btrim(v_item->>'description'),v_qty,nullif(v_item->>'unit_name',''),
      v_price,v_line_discount,v_rate,v_tax_line,
      greatest(0,round(v_qty*v_price)-v_line_discount-v_allocated_header_discount)+v_tax_line,
      v_count
    );
  end loop;
  v_total:=greatest(0,v_subtotal-v_line_discounts-v_header_discount)+v_tax;
  update public.documents
  set contact_id=p_contact_id,
      warehouse_id=p_warehouse_id,
      fiscal_period_id=p_fiscal_period_id,
      document_date=coalesce(p_document_date,current_date),
      due_date=p_due_date,
      discount_amount=v_header_discount+v_line_discounts,
      subtotal=v_subtotal,
      taxable_amount=v_base_total-v_header_discount,
      tax_amount=v_tax,
      total_amount=v_total,
      notes=nullif(btrim(coalesce(p_notes,'')),''),
      version=version+1
  where id=v_doc_id and business_id=p_business_id and status='draft';
  if not found then raise exception using errcode='40001',message='Draft changed while editing'; end if;
  return v_doc_id;
exception
  when unique_violation then raise;
end;
$function$;


revoke all on function public.web_update_document_draft(uuid,uuid,text,uuid,uuid,uuid,date,date,text,numeric,numeric,jsonb,text) from public,anon;
grant execute on function public.web_update_document_draft(uuid,uuid,text,uuid,uuid,uuid,date,date,text,numeric,numeric,jsonb,text) to authenticated;
