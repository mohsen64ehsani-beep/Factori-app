-- 017: customer receipt transaction, allocation, ledger, journal and idempotency.
begin;

do $test$
declare
  v_owner uuid:='88000000-0000-4000-8000-000000000001';
  v_other uuid:='88000000-0000-4000-8000-000000000002';
  v_business uuid:='89000000-0000-4000-8000-000000000001';
  v_other_business uuid:='89000000-0000-4000-8000-000000000002';
  v_contact uuid;
  v_account uuid;
  v_document uuid;
  v_transaction uuid;
  v_replay uuid;
  v_journal uuid;
  v_count integer;
  v_debit numeric;
  v_credit numeric;
  v_failed boolean:=false;
begin
  insert into auth.users(id,email,email_confirmed_at)
  values(v_owner,'receipt-owner@example.test',now()),(v_other,'receipt-outsider@example.test',now())
  on conflict(id) do nothing;

  insert into public.businesses(id,name,owner_user_id)
  values(v_business,'Receipt business',v_owner),(v_other_business,'Other receipt business',v_other)
  on conflict(id) do nothing;

  insert into public.business_members(business_id,user_id,role_code,status,joined_at)
  values(v_business,v_owner,'owner','active',now()),(v_other_business,v_other,'owner','active',now())
  on conflict(business_id,user_id) do nothing;

  insert into public.contacts(business_id,contact_type,name,legacy_id)
  values(v_business,'customer','Receipt customer','receipt-customer')
  returning id into v_contact;

  select id into v_account from public.financial_accounts
  where business_id=v_business and is_default and is_active;

  insert into public.documents(business_id,document_type,contact_id,document_date,status,total_amount,subtotal,taxable_amount,posted_at)
  values(v_business,'goods_sale',v_contact,current_date,'posted',1000,1000,1000,now())
  returning id into v_document;

  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  v_transaction:=public.post_customer_receipt(
    v_business,v_contact,v_account,600,current_date,v_document,500,'RCPT-1','partial receipt','receipt-key-001'
  );
  v_replay:=public.post_customer_receipt(
    v_business,v_contact,v_account,600,current_date,v_document,500,'RCPT-1','partial receipt','receipt-key-001'
  );
  if v_transaction<>v_replay then raise exception 'Idempotent replay must return the original transaction'; end if;

  if (select count(*) from public.financial_transactions where business_id=v_business and id=v_transaction)<>1 then
    raise exception 'Receipt transaction must be created once';
  end if;
  if (select amount from public.financial_transactions where business_id=v_business and id=v_transaction)<>600 then
    raise exception 'Receipt amount mismatch';
  end if;
  if (select sum(amount) from public.transaction_allocations where business_id=v_business and transaction_id=v_transaction)<>500 then
    raise exception 'Receipt allocation amount mismatch';
  end if;

  select je.id into v_journal from public.journal_entries je
  where je.business_id=v_business and je.source_id=v_transaction and je.source_type='financial_transaction';
  if v_journal is null or (select status from public.journal_entries where business_id=v_business and id=v_journal)<>'posted' then
    raise exception 'Receipt must create a posted journal entry';
  end if;
  select count(*),sum(debit),sum(credit) into v_count,v_debit,v_credit
  from public.journal_lines where business_id=v_business and journal_entry_id=v_journal;
  if v_count<>3 or v_debit<>600 or v_credit<>600 then
    raise exception 'Receipt journal must balance and split receivable/advance amounts';
  end if;

  if (select credit from public.contact_ledger_entries where business_id=v_business and transaction_id=v_transaction)<>600 then
    raise exception 'Customer ledger must reflect the full receipt';
  end if;

  begin
    perform public.post_customer_receipt(
      v_business,v_contact,v_account,601,current_date,v_document,500,'RCPT-1','partial receipt','receipt-key-001'
    );
  exception when unique_violation then
    v_failed:=true;
  end;
  if not v_failed then raise exception 'Reusing a receipt idempotency key with changed data must fail'; end if;

  v_failed:=false;
  perform set_config('request.jwt.claim.sub',v_other::text,true);
  begin
    perform public.post_customer_receipt(
      v_business,v_contact,v_account,100,current_date,null,0,'','unauthorized','receipt-key-outsider'
    );
  exception when insufficient_privilege then
    v_failed:=true;
  end;
  if not v_failed then raise exception 'A user outside the business must not post a receipt'; end if;

  -- A receipt without an invoice is a customer advance, not an unallocated receivable.
  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  v_replay:=public.post_customer_receipt(
    v_business,v_contact,v_account,250,current_date,null,0,'RCPT-2','advance receipt','receipt-key-002'
  );
  select je.id into v_journal from public.journal_entries je
  where je.business_id=v_business and je.source_id=v_replay and je.source_type='financial_transaction';
  if not exists(
    select 1 from public.journal_lines jl
    join public.chart_of_accounts coa on coa.business_id=jl.business_id and coa.id=jl.account_id
    where jl.business_id=v_business and jl.journal_entry_id=v_journal and coa.code='2200' and jl.credit=250
  ) then raise exception 'Unallocated receipt must post to customer advances'; end if;
end;
$test$;

rollback;
