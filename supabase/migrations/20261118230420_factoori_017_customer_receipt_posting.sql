-- 017: Atomic customer receipt posting with allocations, customer ledger, and balanced journal.
-- DEVELOPMENT DRAFT ONLY. Does not import legacy payments or alter existing production data.
begin;

alter table public.financial_transactions
  add column if not exists request_fingerprint text;

create unique index if not exists transaction_allocations_one_document_per_transaction
  on public.transaction_allocations(business_id,transaction_id,document_id);

create or replace function public.post_customer_receipt(
  p_business_id uuid,
  p_contact_id uuid,
  p_financial_account_id uuid,
  p_amount numeric,
  p_transaction_date date,
  p_document_id uuid,
  p_allocated_amount numeric,
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
    where ta.business_id=p_business_id and ta.document_id=p_document_id;
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
$$;

revoke all on function public.post_customer_receipt(uuid,uuid,uuid,numeric,date,uuid,numeric,text,text,text) from public,anon;
grant execute on function public.post_customer_receipt(uuid,uuid,uuid,numeric,date,uuid,numeric,text,text,text) to authenticated;

commit;
