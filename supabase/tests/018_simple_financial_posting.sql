-- 018: supplier payment, expense payment, and other-income posting.
begin;

do $test$
declare
  v_owner uuid:='90000000-0000-4000-8000-000000000001';
  v_outsider uuid:='90000000-0000-4000-8000-000000000002';
  v_business uuid:='91000000-0000-4000-8000-000000000001';
  v_other_business uuid:='91000000-0000-4000-8000-000000000002';
  v_supplier uuid;
  v_account uuid;
  v_supplier_tx uuid;
  v_expense_tx uuid;
  v_income_tx uuid;
  v_journal uuid;
  v_replay uuid;
  v_count integer;
  v_debit numeric;
  v_credit numeric;
  v_failed boolean:=false;
begin
  insert into auth.users(id,email,email_confirmed_at)
  values(v_owner,'simple-finance-owner@example.test',now()),(v_outsider,'simple-finance-outsider@example.test',now())
  on conflict(id) do nothing;

  insert into public.businesses(id,name,owner_user_id)
  values(v_business,'Simple finance business',v_owner),(v_other_business,'Other simple finance business',v_outsider)
  on conflict(id) do nothing;
  insert into public.business_members(business_id,user_id,role_code,status,joined_at)
  values(v_business,v_owner,'owner','active',now()),(v_other_business,v_outsider,'owner','active',now())
  on conflict(business_id,user_id) do nothing;

  insert into public.contacts(business_id,contact_type,name,legacy_id)
  values(v_business,'supplier','Test supplier','simple-supplier')
  returning id into v_supplier;
  select id into v_account from public.financial_accounts
  where business_id=v_business and is_default and is_active;

  perform set_config('request.jwt.claim.sub',v_owner::text,true);
  v_supplier_tx:=public.post_simple_financial_transaction(
    v_business,'supplier_payment',v_supplier,v_account,300,current_date,'SUP-1','supplier settlement','simple-key-001'
  );
  v_replay:=public.post_simple_financial_transaction(
    v_business,'supplier_payment',v_supplier,v_account,300,current_date,'SUP-1','supplier settlement','simple-key-001'
  );
  if v_supplier_tx<>v_replay then raise exception 'Supplier payment replay must return the original transaction'; end if;

  v_expense_tx:=public.post_simple_financial_transaction(
    v_business,'expense_payment',null,v_account,150,current_date,'EXP-1','office expense','simple-key-002'
  );
  v_income_tx:=public.post_simple_financial_transaction(
    v_business,'other_income',null,v_account,90,current_date,'INC-1','other income','simple-key-003'
  );

  if (select count(*) from public.financial_transactions
      where business_id=v_business and id in (v_supplier_tx,v_expense_tx,v_income_tx))<>3 then
    raise exception 'Expected all three financial transaction records';
  end if;

  if (select debit from public.contact_ledger_entries
      where business_id=v_business and transaction_id=v_supplier_tx)<>300 then
    raise exception 'Supplier ledger must reflect the payment debit';
  end if;

  for v_journal in
    select id from public.journal_entries
    where business_id=v_business and source_type='financial_transaction'
      and source_id in (v_supplier_tx,v_expense_tx,v_income_tx)
  loop
    select count(*),sum(debit),sum(credit) into v_count,v_debit,v_credit
    from public.journal_lines where business_id=v_business and journal_entry_id=v_journal;
    if v_count<>2 or v_debit<>v_credit or v_debit<=0 then
      raise exception 'Simple financial transaction journal is not balanced';
    end if;
    if (select status from public.journal_entries where business_id=v_business and id=v_journal)<>'posted' then
      raise exception 'Simple financial transaction journal must be posted';
    end if;
  end loop;

  v_failed:=false;
  begin
    perform public.post_simple_financial_transaction(
      v_business,'expense_payment',null,v_account,151,current_date,'EXP-1','office expense','simple-key-002'
    );
  exception when unique_violation then
    v_failed:=true;
  end;
  if not v_failed then raise exception 'Changed amount must not reuse an idempotency key'; end if;

  v_failed:=false;
  perform set_config('request.jwt.claim.sub',v_outsider::text,true);
  begin
    perform public.post_simple_financial_transaction(
      v_business,'expense_payment',null,v_account,20,current_date,'','outsider','outsider-key-01'
    );
  exception when insufficient_privilege then
    v_failed:=true;
  end;
  if not v_failed then raise exception 'Cross-business financial posting must be denied'; end if;
end;
$test$;

rollback;
