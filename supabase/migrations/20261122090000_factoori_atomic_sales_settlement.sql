-- Atomic sales invoice posting with cash / received-cheque settlement.
-- Existing financial RPCs remain the single source of truth for ledger entries.
alter table public.cheques
  add column if not exists related_document_id uuid;

do $migration$
begin
 if not exists (
  select 1 from pg_constraint
  where conrelid='public.cheques'::regclass
    and conname='cheques_business_related_document_fkey'
 ) then
  alter table public.cheques
   add constraint cheques_business_related_document_fkey
   foreign key (business_id,related_document_id)
   references public.documents(business_id,id) on delete restrict;
 end if;
end;
$migration$;

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
security definer
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
 if auth.uid() is null then
  raise exception using errcode='28000',message='Authentication required';
 end if;
 if p_business_id is null
   or not private.has_business_permission(p_business_id,'sales.create')
   or not private.has_business_permission(p_business_id,'sales.post') then
  raise exception using errcode='42501',message='Sales document creation or posting is not permitted';
 end if;
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
 if v_mode in ('cash','cheque','mixed')
   and not private.has_business_permission(p_business_id,'payments.create') then
  raise exception using errcode='42501',message='Customer payment creation is not permitted';
 end if;
 if v_mode in ('cheque','mixed')
   and not private.has_business_permission(p_business_id,'cheques.update_status') then
  raise exception using errcode='42501',message='Cheque creation is not permitted';
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


-- Preserve allocation history while excluding allocations reversed with a cleared-cheque reversal.
alter table public.transaction_allocations
 add column if not exists reversed_by_transaction_id uuid;

do $migration$
begin
 if not exists (
  select 1 from pg_constraint
  where conrelid='public.transaction_allocations'::regclass
    and conname='transaction_allocations_business_reversed_by_fkey'
 ) then
  alter table public.transaction_allocations
   add constraint transaction_allocations_business_reversed_by_fkey
   foreign key (business_id,reversed_by_transaction_id)
   references public.financial_transactions(business_id,id) on delete restrict;
 end if;
end;
$migration$;

create index if not exists transaction_allocations_active_document_idx
 on public.transaction_allocations(business_id,document_id)
 where reversed_by_transaction_id is null;

create or replace function private.mark_cheque_allocations_reversed()
returns trigger
language plpgsql
security invoker
set search_path=''
as $function$
begin
 update public.transaction_allocations
 set reversed_by_transaction_id=new.reversal_transaction_id
 where business_id=new.business_id
   and transaction_id=new.original_transaction_id
   and reversed_by_transaction_id is null;
 return new;
end;
$function$;

revoke all on function private.mark_cheque_allocations_reversed() from public,anon,authenticated;

drop trigger if exists mark_cheque_allocations_reversed
 on private.financial_transaction_reversals;
create trigger mark_cheque_allocations_reversed
 after insert on private.financial_transaction_reversals
 for each row execute function private.mark_cheque_allocations_reversed();

CREATE OR REPLACE FUNCTION public.post_customer_receipt(p_business_id uuid, p_contact_id uuid, p_financial_account_id uuid, p_amount numeric, p_transaction_date date, p_document_id uuid, p_allocated_amount numeric, p_reference_number text, p_description text, p_idempotency_key text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid:=auth.uid();
  v_currency text;
  v_account_currency text;
  v_account_type text;
  v_cash_account_id uuid;
  v_receivable_account_id uuid;
  v_advance_account_id uuid;
  v_transaction_id uuid;
  v_journal_id uuid;
  v_existing_fingerprint text;
  v_fingerprint text;
  v_allocated numeric(20,0):=0;
  v_outstanding numeric(20,0);
  v_document record;
  v_period_id uuid;
  v_expected_cash_code text;
begin
  if v_user is null then
    raise exception using errcode='28000',message='Authentication required';
  end if;
  if not private.has_business_permission(p_business_id,'payments.create') then
    raise exception using errcode='42501',message='Customer receipt is not permitted';
  end if;
  if p_contact_id is null or p_financial_account_id is null or p_amount is null
    or p_amount::text in ('NaN','Infinity','-Infinity')
    or p_amount<=0 or trunc(p_amount)<>p_amount or p_amount>999999999999999999
    or p_transaction_date is null
    or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 160
    or length(btrim(coalesce(p_reference_number,'')))>120
    or length(btrim(coalesce(p_description,'')))>500 then
    raise exception using errcode='22023',message='Invalid customer receipt fields';
  end if;

  if p_document_id is null then
    if coalesce(p_allocated_amount,0)<>0 then
      raise exception using errcode='22023',message='An allocation requires a sales document';
    end if;
    v_allocated:=0;
  else
    v_allocated:=coalesce(p_allocated_amount,p_amount);
    if v_allocated::text in ('NaN','Infinity','-Infinity')
      or v_allocated<=0 or v_allocated>p_amount or trunc(v_allocated)<>v_allocated then
      raise exception using errcode='22023',message='Invalid receipt allocation amount';
    end if;
  end if;

  v_fingerprint:=md5(jsonb_build_array(
    p_business_id,p_contact_id,p_financial_account_id,p_amount,p_transaction_date,
    p_document_id,v_allocated,nullif(btrim(coalesce(p_reference_number,'')),''),
    nullif(btrim(coalesce(p_description,'')),'')
  )::text);
  perform pg_advisory_xact_lock(hashtextextended(p_business_id::text||':customer-receipt:'||p_idempotency_key,0));

  select id,request_fingerprint into v_transaction_id,v_existing_fingerprint
  from public.financial_transactions
  where business_id=p_business_id and idempotency_key=p_idempotency_key;
  if v_transaction_id is not null then
    if v_existing_fingerprint is distinct from v_fingerprint then
      raise exception using errcode='23505',message='Idempotency key was already used with different receipt data';
    end if;
    return v_transaction_id;
  end if;

  select coalesce(bs.currency_code,'IRR') into v_currency
  from public.business_settings bs where bs.business_id=p_business_id;
  v_currency:=coalesce(v_currency,'IRR');

  if not exists(
    select 1 from public.contacts c
    where c.business_id=p_business_id and c.id=p_contact_id and c.is_active
      and c.contact_type in ('customer','both')
  ) then
    raise exception using errcode='22023',message='Customer contact is missing, inactive, or not a customer';
  end if;

  select fa.currency_code,fa.account_type into v_account_currency,v_account_type
  from public.financial_accounts fa
  where fa.business_id=p_business_id and fa.id=p_financial_account_id
    and fa.is_active
  for update;
  if not found or v_account_currency<>v_currency then
    raise exception using errcode='22023',message='Financial account is missing, inactive, or uses a different currency';
  end if;

  v_expected_cash_code:=case v_account_type
    when 'cash' then '1000'
    when 'bank' then '1010'
    when 'wallet' then '1020'
    when 'clearing' then '1030'
    else null end;
  if v_expected_cash_code is null then
    raise exception using errcode='22023',message='Unsupported financial account type';
  end if;

  select m.chart_account_id into v_cash_account_id
  from public.financial_account_ledger_map m
  join public.chart_of_accounts coa
    on coa.business_id=m.business_id and coa.id=m.chart_account_id
  where m.business_id=p_business_id and m.financial_account_id=p_financial_account_id
    and coa.code=v_expected_cash_code and coa.account_class='asset'
    and coa.is_active and coa.allow_posting;
  if v_cash_account_id is null then
    raise exception using errcode='55000',message='Financial account has no valid ledger mapping';
  end if;

  select id into v_receivable_account_id from public.chart_of_accounts
  where business_id=p_business_id and code='1100' and account_class='asset'
    and is_active and allow_posting;
  select id into v_advance_account_id from public.chart_of_accounts
  where business_id=p_business_id and code='2200' and account_class='liability'
    and is_active and allow_posting;
  if v_receivable_account_id is null or v_advance_account_id is null then
    raise exception using errcode='55000',message='Customer control accounts are not configured';
  end if;

  if p_document_id is not null then
    select d.id,d.contact_id,d.document_type,d.status,d.total_amount,d.fiscal_period_id
      into v_document
    from public.documents d
    where d.business_id=p_business_id and d.id=p_document_id
    for update;
    if not found or v_document.status<>'posted'
      or v_document.document_type not in ('goods_sale','service_sale')
      or v_document.contact_id is distinct from p_contact_id then
      raise exception using errcode='22023',message='Receipt allocation must target a posted sales document for this customer';
    end if;
    select v_document.total_amount-coalesce(sum(ta.amount),0) into v_outstanding
    from public.transaction_allocations ta
    where ta.business_id=p_business_id and ta.document_id=p_document_id
      and ta.reversed_by_transaction_id is null;
    if v_allocated>v_outstanding then
      raise exception using errcode='23514',message='Receipt allocation exceeds the document outstanding balance';
    end if;
  end if;

  select fp.id into v_period_id
  from public.fiscal_periods fp
  where fp.business_id=p_business_id and p_transaction_date between fp.date_from and fp.date_to
  order by fp.date_from desc
  limit 1;
  if v_period_id is not null and not exists(
    select 1 from public.fiscal_periods fp
    where fp.business_id=p_business_id and fp.id=v_period_id and fp.status in ('open','reopened')
  ) then
    raise exception using errcode='22023',message='Transaction date is in a closed fiscal period';
  end if;

  insert into public.financial_transactions(
    business_id,transaction_type,direction,amount,currency_code,transaction_date,
    account_id,contact_id,document_id,reference_number,description,status,
    idempotency_key,request_fingerprint,created_by
  ) values (
    p_business_id,'customer_receipt','in',p_amount,v_currency,p_transaction_date,
    p_financial_account_id,p_contact_id,p_document_id,
    nullif(btrim(coalesce(p_reference_number,'')),''),
    nullif(btrim(coalesce(p_description,'')),''),'posted',
    p_idempotency_key,v_fingerprint,v_user
  ) returning id into v_transaction_id;

  if p_document_id is not null and v_allocated>0 then
    insert into public.transaction_allocations(business_id,transaction_id,document_id,amount,created_by)
    values(p_business_id,v_transaction_id,p_document_id,v_allocated,v_user);
  end if;

  insert into public.journal_entries(
    business_id,entry_date,fiscal_period_id,source_type,source_id,description,
    status,idempotency_key,created_by
  ) values (
    p_business_id,p_transaction_date,v_period_id,'financial_transaction',v_transaction_id,
    coalesce(nullif(btrim(coalesce(p_description,'')),''),'دریافت از مشتری'),
    'draft','customer-receipt:'||p_idempotency_key,v_user
  ) returning id into v_journal_id;

  insert into public.journal_lines(
    business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order
  ) values (p_business_id,v_journal_id,v_cash_account_id,null,p_amount,0,'دریافت وجه',1);

  if v_allocated>0 then
    insert into public.journal_lines(
      business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order
    ) values (
      p_business_id,v_journal_id,v_receivable_account_id,p_contact_id,0,v_allocated,'تسویه مطالبات',2
    );
  end if;

  if p_amount>v_allocated then
    insert into public.journal_lines(
      business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order
    ) values (
      p_business_id,v_journal_id,v_advance_account_id,p_contact_id,0,p_amount-v_allocated,
      'پیش‌دریافت مشتری',case when v_allocated>0 then 3 else 2 end
    );
  end if;

  update public.journal_entries
  set status='posted',posted_at=now(),posted_by=v_user,version=version+1
  where business_id=p_business_id and id=v_journal_id;

  insert into public.contact_ledger_entries(
    business_id,contact_id,entry_date,entry_type,debit,credit,transaction_id,description,source_legacy_id,created_by
  ) values (
    p_business_id,p_contact_id,p_transaction_date,'receipt',0,p_amount,v_transaction_id,
    coalesce(nullif(btrim(coalesce(p_description,'')),''),'دریافت وجه'),
    'financial_transaction:'||v_transaction_id::text,v_user
  );

  return v_transaction_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.transition_cheque(p_business_id uuid, p_cheque_id uuid, p_to_status text, p_event_date date, p_financial_account_id uuid, p_note text, p_idempotency_key text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_user uuid:=auth.uid();
 v_cheque record;
 v_event_id uuid;
 v_existing_fingerprint text;
 v_fingerprint text;
 v_transaction_id uuid;
 v_allowed boolean:=false;
 v_event_type text;
begin
 if v_user is null then
  raise exception using errcode='28000',message='Authentication required';
 end if;
 if not private.has_business_permission(p_business_id,'cheques.update_status') then
  raise exception using errcode='42501',message='Cheque status update is not permitted';
 end if;
 if p_cheque_id is null or p_to_status is null or p_to_status not in ('deposited','cleared','bounced','cancelled','returned')
  or p_event_date is null
  or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 120
  or length(btrim(coalesce(p_note,'')))>500 then
  raise exception using errcode='22023',message='Invalid cheque transition';
 end if;

 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text||':cheque-event:'||p_idempotency_key,0));
 select * into v_cheque from public.cheques
 where business_id=p_business_id and id=p_cheque_id for update;
 if not found then
  raise exception using errcode='P0002',message='Cheque not found';
 end if;
 if v_cheque.issue_date is not null and p_event_date<v_cheque.issue_date then
  raise exception using errcode='22023',message='Cheque event date cannot precede its issue date';
 end if;

 v_fingerprint:=md5(jsonb_build_array(
  p_business_id,p_cheque_id,p_to_status,p_event_date,
  p_financial_account_id,nullif(btrim(coalesce(p_note,'')),'')
 )::text);
 select id,request_fingerprint into v_event_id,v_existing_fingerprint
 from public.cheque_events where business_id=p_business_id and idempotency_key=p_idempotency_key;
 if v_event_id is not null then
  if v_existing_fingerprint is distinct from v_fingerprint then
   raise exception using errcode='23505',message='Cheque event idempotency key was already used with different data';
  end if;
  return v_event_id;
 end if;

 if v_cheque.cheque_direction='received' then
  v_allowed:=(v_cheque.status='pending' and p_to_status in ('deposited','cleared','bounced','cancelled','returned'))
    or (v_cheque.status='deposited' and p_to_status in ('cleared','bounced','cancelled','returned'));
 else
  v_allowed:=(v_cheque.status='pending' and p_to_status in ('cleared','bounced','cancelled'));
 end if;
 if not v_allowed then
  raise exception using errcode='55000',message='Cheque transition is not allowed; cleared cheque reversals require a separate audited reversal';
 end if;

 if p_to_status='cleared' then
  if p_financial_account_id is null then
   raise exception using errcode='22023',message='A financial account is required to clear a cheque';
  end if;
  if not private.has_business_permission(p_business_id,'payments.create') then
   raise exception using errcode='42501',message='Cheque settlement is not permitted';
  end if;
  if v_cheque.cheque_direction='received' then
   v_transaction_id:=public.post_customer_receipt(
    p_business_id,v_cheque.contact_id,p_financial_account_id,v_cheque.amount,
    p_event_date,v_cheque.related_document_id,
    case when v_cheque.related_document_id is null then 0 else v_cheque.amount end,
    v_cheque.cheque_number,
    coalesce(nullif(btrim(coalesce(p_note,'')),''),'وصول چک دریافتی'),
    'cheque-received-clear:'||p_cheque_id::text
   );
  else
   v_transaction_id:=public.post_simple_financial_transaction(
    p_business_id,'supplier_payment',v_cheque.contact_id,p_financial_account_id,
    v_cheque.amount,p_event_date,v_cheque.cheque_number,
    coalesce(nullif(btrim(coalesce(p_note,'')),''),'وصول چک پرداختی'),
    'cheque-issued-clear:'||p_cheque_id::text
   );
  end if;
 elsif p_financial_account_id is not null then
  raise exception using errcode='22023',message='Financial account is only accepted when clearing a cheque';
 end if;

 v_event_type:=case p_to_status
  when 'deposited' then 'deposited'
  when 'cleared' then 'cleared'
  when 'bounced' then 'bounced'
  when 'cancelled' then 'cancelled'
  when 'returned' then 'returned'
 end;

 update public.cheques
 set status=p_to_status,
  related_transaction_id=coalesce(v_transaction_id,related_transaction_id),
  version=version+1,updated_at=now()
 where business_id=p_business_id and id=p_cheque_id;

 insert into public.cheque_events(
  business_id,cheque_id,event_type,event_date,from_status,to_status,amount,
  related_transaction_id,related_contact_id,note,idempotency_key,request_fingerprint,created_by
 ) values(
  p_business_id,p_cheque_id,v_event_type,p_event_date::timestamptz,
  v_cheque.status,p_to_status,v_cheque.amount,v_transaction_id,v_cheque.contact_id,
  nullif(btrim(coalesce(p_note,'')),''),p_idempotency_key,v_fingerprint,v_user
 ) returning id into v_event_id;
 return v_event_id;
end;
$function$
;
