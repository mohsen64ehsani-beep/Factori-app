-- Atomic sales invoice posting with cash / received-cheque settlement.
-- Existing financial RPCs remain the single source of truth for ledger entries.
alter table public.cheques
  add column if not exists related_document_id uuid
  references public.documents(id) on delete restrict;

create index if not exists cheques_business_related_document_idx
  on public.cheques(business_id, related_document_id)
  where related_document_id is not null;

create or replace function public.create_and_settle_sales_document(
 p_business_id uuid,
 p_document_type text,
 p_contact_id uuid,
 p_warehouse_id uuid,
 p_fiscal_period_id uuid,
 p_document_date date,
 p_due_date date,
 p_notes text,
 p_discount_amount numeric,
 p_tax_rate numeric,
 p_items jsonb,
 p_idempotency_key text,
 p_payment jsonb
)
returns uuid
language plpgsql
security invoker
set search_path=''
as $function$
declare
 v_document_id uuid;
 v_total numeric(20,0);
 v_mode text;
 v_cash numeric;
 v_cheque numeric;
 v_cash_account_id uuid;
 v_cheque_id uuid;
 v_payment_date date;
 v_cheque_due_date date;
 v_cheque_issue_date date;
 v_cheque_number text;
begin
 if p_document_type not in ('goods_sale','service_sale') then
  raise exception using errcode='22023',message='Settlement is supported only for sales documents';
 end if;
 if p_payment is null or jsonb_typeof(p_payment)<>'object' then
  raise exception using errcode='22023',message='Payment details are required';
 end if;

 v_mode:=coalesce(p_payment->>'mode','credit');
 if v_mode not in ('credit','cash','cheque','mixed') then
  raise exception using errcode='22023',message='Unsupported payment mode';
 end if;
 v_cash:=coalesce(nullif(p_payment->>'cash_amount','')::numeric,0);
 v_cheque:=coalesce(nullif(p_payment->>'cheque_amount','')::numeric,0);
 v_cash_account_id:=nullif(p_payment->>'cash_account_id','')::uuid;
 v_payment_date:=coalesce(p_document_date,current_date);

 if v_cash<0 or v_cheque<0 or trunc(v_cash)<>v_cash or trunc(v_cheque)<>v_cheque then
  raise exception using errcode='22023',message='Payment amounts must be non-negative whole currency units';
 end if;
 if v_mode='credit' and (v_cash<>0 or v_cheque<>0) then
  raise exception using errcode='22023',message='Credit invoices cannot include settlement amounts';
 end if;
 if v_mode='cash' and (v_cash<=0 or v_cheque<>0 or v_cash_account_id is null) then
  raise exception using errcode='22023',message='Cash payment requires a positive amount and financial account';
 end if;
 if v_mode='cheque' and (v_cash<>0 or v_cheque<=0) then
  raise exception using errcode='22023',message='Cheque payment requires a positive cheque amount';
 end if;
 if v_mode='mixed' and (v_cash<=0 or v_cheque<=0 or v_cash_account_id is null) then
  raise exception using errcode='22023',message='Mixed payment requires positive cash and cheque amounts';
 end if;

 v_document_id:=public.create_and_post_document(
  p_business_id,p_document_type,p_contact_id,p_warehouse_id,p_fiscal_period_id,
  p_document_date,p_due_date,p_notes,p_discount_amount,p_tax_rate,p_items,p_idempotency_key
 );

 select d.total_amount into v_total
 from public.documents d
 where d.business_id=p_business_id and d.id=v_document_id and d.status='posted'
 for update;
 if not found then
  raise exception using errcode='55000',message='Posted sales document was not found';
 end if;

 if v_mode in ('cash','cheque','mixed') and v_cash+v_cheque<>v_total then
  raise exception using errcode='22023',message='Cash and cheque amounts must exactly equal the invoice total';
 end if;

 if v_cash>0 then
  perform public.post_customer_receipt(
   p_business_id,p_contact_id,v_cash_account_id,v_cash,v_payment_date,
   v_document_id,v_cash,null,
   'دریافت نقدی بابت فاکتور',
   left(p_idempotency_key,130)||':cash'
  );
 end if;

 if v_cheque>0 then
  v_cheque_number:=nullif(btrim(coalesce(p_payment->>'cheque_number','')),'');
  v_cheque_issue_date:=nullif(p_payment->>'cheque_issue_date','')::date;
  v_cheque_due_date:=nullif(p_payment->>'cheque_due_date','')::date;
  if v_cheque_number is null or v_cheque_due_date is null then
   raise exception using errcode='22023',message='Cheque number and due date are required';
  end if;

  v_cheque_id:=public.create_cheque(
   p_business_id,'received',p_contact_id,v_cheque_number,
   nullif(p_payment->>'sayad_id',''),nullif(p_payment->>'bank_name',''),
   nullif(p_payment->>'branch_name',''),null,
   nullif(p_payment->>'account_holder',''),nullif(p_payment->>'drawer_name',''),
   nullif(p_payment->>'payee_name',''),v_cheque,v_cheque_issue_date,
   v_cheque_due_date,
   coalesce(nullif(p_payment->>'cheque_note',''),'چک بابت فاکتور فروش'),
   left(p_idempotency_key,110)||':cheque'
  );

  update public.cheques
  set related_document_id=v_document_id,updated_at=now(),version=version+1
  where business_id=p_business_id and id=v_cheque_id
    and (related_document_id is null or related_document_id=v_document_id);
  if not found then
   raise exception using errcode='23514',message='Cheque is already linked to another document';
  end if;
 end if;

 return v_document_id;
end;
$function$;

revoke all on function public.create_and_settle_sales_document(uuid,text,uuid,uuid,uuid,date,date,text,numeric,numeric,jsonb,text,jsonb) from public,anon;
grant execute on function public.create_and_settle_sales_document(uuid,text,uuid,uuid,uuid,date,date,text,numeric,numeric,jsonb,text,jsonb) to authenticated;
