create or replace function public.create_and_post_document(
 p_business_id uuid,
 p_document_type text,
 p_contact_id uuid default null,
 p_warehouse_id uuid default null,
 p_fiscal_period_id uuid default null,
 p_document_date date default current_date,
 p_due_date date default null,
 p_notes text default null,
 p_discount_amount numeric default 0,
 p_tax_rate numeric default null,
 p_items jsonb default '[]'::jsonb,
 p_idempotency_key text default null
)
returns uuid language plpgsql security invoker set search_path=''
as $function$
declare v_document_id uuid;
begin
 if p_document_type not in ('goods_sale','service_sale','purchase','service_purchase') then
  raise exception using errcode='22023',message='Unsupported document type';
 end if;
 v_document_id:=public.create_document_draft(
  p_business_id,p_document_type,p_contact_id,p_warehouse_id,p_fiscal_period_id,
  p_document_date,p_due_date,p_notes,p_discount_amount,p_tax_rate,p_items,p_idempotency_key
 );
 if p_document_type='goods_sale' then
  perform public.post_goods_sale_document(p_business_id,v_document_id,p_idempotency_key);
 elsif p_document_type='purchase' then
  perform public.post_purchase_document(p_business_id,v_document_id,p_idempotency_key);
 else
  perform public.post_service_document(p_business_id,v_document_id,p_idempotency_key);
 end if;
 return v_document_id;
end;
$function$;
revoke all on function public.create_and_post_document(uuid,text,uuid,uuid,uuid,date,date,text,numeric,numeric,jsonb,text) from public,anon;
grant execute on function public.create_and_post_document(uuid,text,uuid,uuid,uuid,date,date,text,numeric,numeric,jsonb,text) to authenticated;