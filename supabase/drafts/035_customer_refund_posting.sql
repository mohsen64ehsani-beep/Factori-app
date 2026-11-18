-- 035: Cash refunds against posted goods sales returns, capped by both return value and customer credit.
begin;

alter table public.sales_return_documents
 add column if not exists refunded_amount numeric(20,0) not null default 0;

do $constraint$
begin
 if not exists(
  select 1 from pg_constraint
  where conname='sales_return_refunded_amount_valid'
   and conrelid='public.sales_return_documents'::regclass
 ) then
  alter table public.sales_return_documents
   add constraint sales_return_refunded_amount_valid
   check(refunded_amount>=0 and refunded_amount<=total_amount);
 end if;
end;
$constraint$;

create table if not exists private.customer_refund_allocations (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null,
 sales_return_document_id uuid not null,
 financial_transaction_id uuid not null,
 amount numeric(20,0) not null check(amount>0),
 idempotency_key text not null,
 request_fingerprint text not null,
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 unique(business_id,id),
 unique(business_id,financial_transaction_id),
 unique(business_id,idempotency_key),
 foreign key(business_id,sales_return_document_id)
  references public.sales_return_documents(business_id,id),
 foreign key(business_id,financial_transaction_id)
  references public.financial_transactions(business_id,id)
);
alter table private.customer_refund_allocations enable row level security;
revoke all on private.customer_refund_allocations from public,anon,authenticated;

create or replace function public.post_customer_refund(
 p_business_id uuid,
 p_sales_return_document_id uuid,
 p_financial_account_id uuid,
 p_amount numeric,
 p_transaction_date date,
 p_reference_number text,
 p_description text,
 p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
 v_user uuid:=auth.uid();
 v_return record;
 v_currency text;
 v_account_currency text;
 v_account_type text;
 v_cash_code text;
 v_cash_account_id uuid;
 v_receivable_account_id uuid;
 v_refundable numeric(20,0);
 v_customer_credit numeric(20,0);
 v_transaction_id uuid;
 v_existing_fingerprint text;
 v_fingerprint text;
 v_journal_id uuid;
 v_period_id uuid;
begin
 if v_user is null then
  raise exception using errcode='28000',message='Authentication required';
 end if;
 if not private.has_business_permission(p_business_id,'payments.create') then
  raise exception using errcode='42501',message='Customer refund is not permitted';
 end if;
 if p_sales_return_document_id is null or p_financial_account_id is null
  or p_amount is null or p_amount::text in ('NaN','Infinity','-Infinity')
  or p_amount<=0 or trunc(p_amount)<>p_amount or p_amount>999999999999999999
  or p_transaction_date is null
  or length(btrim(coalesce(p_reference_number,'')))>120
  or length(btrim(coalesce(p_description,'')))>500
  or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 160 then
  raise exception using errcode='22023',message='Invalid customer refund fields';
 end if;

 perform pg_advisory_xact_lock(hashtextextended(
  p_business_id::text||':customer-refund:'||p_sales_return_document_id::text,0));
 perform pg_advisory_xact_lock(hashtextextended(
  p_business_id::text||':customer-refund-key:'||p_idempotency_key,0));

 select * into v_return
 from public.sales_return_documents rd
 where rd.business_id=p_business_id and rd.id=p_sales_return_document_id
 for update;
 if not found then
  raise exception using errcode='P0002',message='Sales return document not found';
 end if;
 if v_return.status<>'posted' then
  raise exception using errcode='55000',message='Only a posted sales return can be refunded';
 end if;

 v_fingerprint:=md5(jsonb_build_array(
  p_business_id,p_sales_return_document_id,p_financial_account_id,p_amount,
  p_transaction_date,nullif(btrim(coalesce(p_reference_number,'')),''),
  nullif(btrim(coalesce(p_description,'')),'')
 )::text);
 select ft.id,ft.request_fingerprint into v_transaction_id,v_existing_fingerprint
 from public.financial_transactions ft
 where ft.business_id=p_business_id and ft.idempotency_key=p_idempotency_key;
 if v_transaction_id is not null then
  if v_existing_fingerprint is distinct from v_fingerprint
   or not exists(select 1 from private.customer_refund_allocations a
    where a.business_id=p_business_id and a.financial_transaction_id=v_transaction_id
     and a.sales_return_document_id=p_sales_return_document_id) then
   raise exception using errcode='23505',message='Customer refund idempotency key was used with different data';
  end if;
  return v_transaction_id;
 end if;

 v_refundable:=v_return.total_amount-v_return.refunded_amount;
 if p_amount>v_refundable then
  raise exception using errcode='23514',message='Refund exceeds the remaining amount on this sales return';
 end if;
 select coalesce(sum(cle.credit-cle.debit),0) into v_customer_credit
 from public.contact_ledger_entries cle
 where cle.business_id=p_business_id and cle.contact_id=v_return.contact_id;
 if p_amount>v_customer_credit then
  raise exception using errcode='23514',message='Customer does not have enough net credit for this cash refund';
 end if;

 select coalesce(bs.currency_code,'IRR') into v_currency
 from public.business_settings bs where bs.business_id=p_business_id;
 v_currency:=coalesce(v_currency,'IRR');

 select fa.currency_code,fa.account_type into v_account_currency,v_account_type
 from public.financial_accounts fa
 where fa.business_id=p_business_id and fa.id=p_financial_account_id and fa.is_active
 for update;
 if not found then
  raise exception using errcode='22023',message='Financial account is missing or inactive';
 end if;
 if v_account_currency<>v_currency then
  raise exception using errcode='22023',message='Financial account uses a different currency';
 end if;
 v_cash_code:=case v_account_type
  when 'cash' then '1000'
  when 'bank' then '1010'
  when 'wallet' then '1020'
  when 'clearing' then '1030'
  else null end;
 if v_cash_code is null then
  raise exception using errcode='22023',message='Unsupported financial account type';
 end if;

 select m.chart_account_id into v_cash_account_id
 from public.financial_account_ledger_map m
 join public.chart_of_accounts coa
  on coa.business_id=m.business_id and coa.id=m.chart_account_id
 where m.business_id=p_business_id and m.financial_account_id=p_financial_account_id
  and coa.code=v_cash_code and coa.account_class='asset'
  and coa.is_active and coa.allow_posting;
 select id into v_receivable_account_id from public.chart_of_accounts
 where business_id=p_business_id and code='1100' and account_class='asset'
  and is_active and allow_posting;
 if v_cash_account_id is null or v_receivable_account_id is null then
  raise exception using errcode='55000',message='Customer refund ledger accounts are not configured';
 end if;

 select fp.id into v_period_id from public.fiscal_periods fp
 where fp.business_id=p_business_id and p_transaction_date between fp.date_from and fp.date_to
 order by fp.date_from desc limit 1;
 if v_period_id is not null and not exists(
  select 1 from public.fiscal_periods fp
  where fp.business_id=p_business_id and fp.id=v_period_id and fp.status in ('open','reopened')
 ) then
  raise exception using errcode='22023',message='Refund date is in a closed fiscal period';
 end if;

 insert into public.financial_transactions(
  business_id,transaction_type,direction,amount,currency_code,transaction_date,
  account_id,contact_id,document_id,reference_number,description,status,
  idempotency_key,request_fingerprint,created_by
 ) values(
  p_business_id,'customer_refund','out',p_amount,v_currency,p_transaction_date,
  p_financial_account_id,v_return.contact_id,v_return.original_document_id,
  nullif(btrim(coalesce(p_reference_number,'')),''),
  coalesce(nullif(btrim(coalesce(p_description,'')),''),'بازپرداخت مرجوعی فروش'),
  'posted',p_idempotency_key,v_fingerprint,v_user
 ) returning id into v_transaction_id;

 insert into public.journal_entries(
  business_id,entry_date,fiscal_period_id,source_type,source_id,description,
  status,idempotency_key,created_by
 ) values(
  p_business_id,p_transaction_date,v_period_id,'financial_transaction',v_transaction_id,
  coalesce(nullif(btrim(coalesce(p_description,'')),''),'بازپرداخت مرجوعی فروش'),
  'draft','customer-refund-journal:'||p_idempotency_key,v_user
 ) returning id into v_journal_id;

 insert into public.journal_lines(
  business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order
 ) values
  (p_business_id,v_journal_id,v_receivable_account_id,v_return.contact_id,p_amount,0,'تسویه اعتبار مرجوعی مشتری',1),
  (p_business_id,v_journal_id,v_cash_account_id,null,0,p_amount,'پرداخت وجه به مشتری',2);

 update public.journal_entries
 set status='posted',posted_at=now(),posted_by=v_user,version=version+1
 where business_id=p_business_id and id=v_journal_id;

 insert into public.contact_ledger_entries(
  business_id,contact_id,entry_date,entry_type,debit,credit,transaction_id,
  document_id,description,source_legacy_id,created_by
 ) values(
  p_business_id,v_return.contact_id,p_transaction_date,'adjustment_debit',p_amount,0,
  v_transaction_id,v_return.original_document_id,
  coalesce(nullif(btrim(coalesce(p_description,'')),''),'بازپرداخت مرجوعی فروش'),
  'financial_transaction:'||v_transaction_id::text,v_user
 );

 insert into private.customer_refund_allocations(
  business_id,sales_return_document_id,financial_transaction_id,amount,
  idempotency_key,request_fingerprint,created_by
 ) values(
  p_business_id,p_sales_return_document_id,v_transaction_id,p_amount,
  p_idempotency_key,v_fingerprint,v_user
 );

 update public.sales_return_documents
 set refunded_amount=refunded_amount+p_amount
 where business_id=p_business_id and id=p_sales_return_document_id;

 return v_transaction_id;
end;
$$;

revoke all on function public.post_customer_refund(uuid,uuid,uuid,numeric,date,text,text,text) from public,anon;
grant execute on function public.post_customer_refund(uuid,uuid,uuid,numeric,date,text,text,text) to authenticated;

commit;
