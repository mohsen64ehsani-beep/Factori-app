-- 018: Atomic supplier payments, expense payments, and other-income posting.
-- DEVELOPMENT DRAFT ONLY. Each operation creates a balanced journal and is idempotent.
begin;

create or replace function public.post_simple_financial_transaction(
  p_business_id uuid,
  p_transaction_type text,
  p_contact_id uuid,
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
  v_permission text;
  v_currency text;
  v_account_currency text;
  v_account_type text;
  v_cash_code text;
  v_counterpart_code text;
  v_direction text;
  v_cash_account_id uuid;
  v_counterpart_account_id uuid;
  v_transaction_id uuid;
  v_journal_id uuid;
  v_existing_fingerprint text;
  v_fingerprint text;
  v_period_id uuid;
  v_description text;
begin
  if v_user is null then
    raise exception using errcode='28000',message='Authentication required';
  end if;

  case p_transaction_type
    when 'supplier_payment' then
      v_permission:='payments.create';
      v_counterpart_code:='2000';
      v_direction:='out';
    when 'expense_payment' then
      v_permission:='expenses.create';
      v_counterpart_code:='6000';
      v_direction:='out';
    when 'other_income' then
      v_permission:='payments.create';
      v_counterpart_code:='7000';
      v_direction:='in';
    else
      raise exception using errcode='22023',message='Unsupported financial transaction type';
  end case;

  if not private.has_business_permission(p_business_id,v_permission) then
    raise exception using errcode='42501',message='Financial transaction is not permitted';
  end if;
  if p_financial_account_id is null or p_amount is null
    or p_amount::text in ('NaN','Infinity','-Infinity')
    or p_amount<=0 or trunc(p_amount)<>p_amount or p_amount>999999999999999999
    or p_transaction_date is null
    or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 160
    or length(btrim(coalesce(p_reference_number,'')))>120
    or length(btrim(coalesce(p_description,'')))>500 then
    raise exception using errcode='22023',message='Invalid financial transaction fields';
  end if;

  if p_transaction_type='supplier_payment' then
    if p_contact_id is null or not exists(
      select 1 from public.contacts c
      where c.business_id=p_business_id and c.id=p_contact_id and c.is_active
        and c.contact_type in ('supplier','both')
    ) then
      raise exception using errcode='22023',message='Supplier contact is missing, inactive, or not a supplier';
    end if;
  elsif p_contact_id is not null then
    raise exception using errcode='22023',message='This transaction type does not accept a contact';
  end if;

  v_description:=coalesce(nullif(btrim(coalesce(p_description,'')),''),case p_transaction_type
    when 'supplier_payment' then 'پرداخت به تأمین‌کننده'
    when 'expense_payment' then 'پرداخت هزینه'
    else 'درآمد متفرقه' end);

  v_fingerprint:=md5(jsonb_build_array(
    p_business_id,p_transaction_type,p_contact_id,p_financial_account_id,p_amount,p_transaction_date,
    nullif(btrim(coalesce(p_reference_number,'')),''),
    nullif(btrim(coalesce(p_description,'')),'')
  )::text);
  perform pg_advisory_xact_lock(hashtextextended(p_business_id::text||':simple-financial:'||p_idempotency_key,0));

  select id,request_fingerprint into v_transaction_id,v_existing_fingerprint
  from public.financial_transactions
  where business_id=p_business_id and idempotency_key=p_idempotency_key;
  if v_transaction_id is not null then
    if v_existing_fingerprint is distinct from v_fingerprint then
      raise exception using errcode='23505',message='Idempotency key was already used with different financial data';
    end if;
    return v_transaction_id;
  end if;

  select coalesce(bs.currency_code,'IRR') into v_currency
  from public.business_settings bs where bs.business_id=p_business_id;
  v_currency:=coalesce(v_currency,'IRR');

  select fa.currency_code,fa.account_type into v_account_currency,v_account_type
  from public.financial_accounts fa
  where fa.business_id=p_business_id and fa.id=p_financial_account_id and fa.is_active
  for update;
  if not found or v_account_currency<>v_currency then
    raise exception using errcode='22023',message='Financial account is missing, inactive, or uses a different currency';
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
  if v_cash_account_id is null then
    raise exception using errcode='55000',message='Financial account has no valid ledger mapping';
  end if;

  select id into v_counterpart_account_id from public.chart_of_accounts
  where business_id=p_business_id and code=v_counterpart_code
    and is_active and allow_posting
    and account_class=case when v_counterpart_code='2000' then 'liability'
      when v_counterpart_code='7000' then 'income' else 'expense' end;
  if v_counterpart_account_id is null then
    raise exception using errcode='55000',message='Counterpart ledger account is not configured';
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
    account_id,contact_id,reference_number,description,status,idempotency_key,request_fingerprint,created_by
  ) values (
    p_business_id,p_transaction_type,v_direction,p_amount,v_currency,p_transaction_date,
    p_financial_account_id,p_contact_id,nullif(btrim(coalesce(p_reference_number,'')),''),
    v_description,'posted',p_idempotency_key,v_fingerprint,v_user
  ) returning id into v_transaction_id;

  insert into public.journal_entries(
    business_id,entry_date,fiscal_period_id,source_type,source_id,description,status,idempotency_key,created_by
  ) values (
    p_business_id,p_transaction_date,v_period_id,'financial_transaction',v_transaction_id,
    v_description,'draft','simple-financial:'||p_idempotency_key,v_user
  ) returning id into v_journal_id;

  if p_transaction_type='other_income' then
    insert into public.journal_lines(
      business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order
    ) values
      (p_business_id,v_journal_id,v_cash_account_id,null,p_amount,0,'دریافت وجه',1),
      (p_business_id,v_journal_id,v_counterpart_account_id,null,0,p_amount,'سایر درآمدها',2);
  else
    insert into public.journal_lines(
      business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order
    ) values
      (p_business_id,v_journal_id,v_counterpart_account_id,p_contact_id,p_amount,0,
        case when p_transaction_type='supplier_payment' then 'کاهش بدهی تأمین‌کننده' else 'ثبت هزینه' end,1),
      (p_business_id,v_journal_id,v_cash_account_id,null,0,p_amount,'پرداخت وجه',2);
  end if;

  update public.journal_entries
  set status='posted',posted_at=now(),posted_by=v_user,version=version+1
  where business_id=p_business_id and id=v_journal_id;

  if p_transaction_type='supplier_payment' then
    insert into public.contact_ledger_entries(
      business_id,contact_id,entry_date,entry_type,debit,credit,transaction_id,description,source_legacy_id,created_by
    ) values (
      p_business_id,p_contact_id,p_transaction_date,'payment',p_amount,0,v_transaction_id,
      v_description,'financial_transaction:'||v_transaction_id::text,v_user
    );
  end if;

  return v_transaction_id;
end;
$$;

revoke all on function public.post_simple_financial_transaction(uuid,text,uuid,uuid,numeric,date,text,text,text) from public,anon;
grant execute on function public.post_simple_financial_transaction(uuid,text,uuid,uuid,numeric,date,text,text,text) to authenticated;

commit;
