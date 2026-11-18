-- 033: Reversing a cleared cheque creates an immutable balanced reversal, not a status-only edit.
begin;

do $test$
declare
 v_owner uuid:='d1000000-0000-4000-8000-000000000001';
 v_outsider uuid:='d1000000-0000-4000-8000-000000000002';
 v_business uuid:='d2000000-0000-4000-8000-000000000001';
 v_other_business uuid:='d2000000-0000-4000-8000-000000000002';
 v_customer uuid;
 v_supplier uuid;
 v_account uuid;
 v_received uuid;
 v_issued uuid;
 v_event uuid;
 v_replay uuid;
 v_original_tx uuid;
 v_reversal_tx uuid;
 v_reversal_journal uuid;
 v_count integer;
 v_debit numeric;
 v_credit numeric;
 v_failed boolean:=false;
begin
 insert into auth.users(id,email,email_confirmed_at)
 values(v_owner,'cheque-reverse-owner@example.test',now()),(v_outsider,'cheque-reverse-outsider@example.test',now())
 on conflict(id) do nothing;
 insert into public.businesses(id,name,owner_user_id)
 values(v_business,'Cheque reversal business',v_owner),(v_other_business,'Other cheque reversal business',v_outsider)
 on conflict(id) do nothing;
 insert into public.business_members(business_id,user_id,role_code,status,joined_at)
 values(v_business,v_owner,'owner','active',now()),(v_other_business,v_outsider,'owner','active',now())
 on conflict(business_id,user_id) do nothing;
 insert into public.contacts(business_id,contact_type,name,legacy_id)
 values(v_business,'customer','Reversal customer','reverse-customer')
 returning id into v_customer;
 insert into public.contacts(business_id,contact_type,name,legacy_id)
 values(v_business,'supplier','Reversal supplier','reverse-supplier')
 returning id into v_supplier;
 select id into v_account from public.financial_accounts
 where business_id=v_business and is_default and is_active;

 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_received:=public.create_cheque(
  v_business,'received',v_customer,'CHQ-RCV-REV',null,'Bank','Main',
  '12345','Customer','Customer','Factoori',800,current_date,current_date+7,
  'received then bounced','reverse-create-received-01'
 );
 perform public.transition_cheque(
  v_business,v_received,'cleared',current_date,v_account,'received cleared','reverse-clear-received-01'
 );
 select related_transaction_id into v_original_tx from public.cheques
 where business_id=v_business and id=v_received;
 v_event:=public.reverse_cleared_cheque(
  v_business,v_received,current_date,'customer cheque bounced','reverse-received-001'
 );
 v_replay:=public.reverse_cleared_cheque(
  v_business,v_received,current_date,'customer cheque bounced','reverse-received-001'
 );
 if v_event<>v_replay then raise exception 'Cheque reversal replay must return original event'; end if;
 select reversal_transaction_id into v_reversal_tx from public.cheques
 where business_id=v_business and id=v_received;
 if v_reversal_tx is null or not exists(
  select 1 from public.financial_transactions where business_id=v_business and id=v_reversal_tx
   and transaction_type='customer_refund' and direction='out' and amount=800
 ) then raise exception 'Received cheque reversal must post customer refund'; end if;
 if (select status from public.cheques where business_id=v_business and id=v_received)<>'bounced' then
  raise exception 'Reversed received cheque must be marked bounced';
 end if;
 select reversal_journal_entry_id into v_reversal_journal
 from private.financial_transaction_reversals
 where business_id=v_business and original_transaction_id=v_original_tx;
 select count(*),sum(debit),sum(credit) into v_count,v_debit,v_credit
 from public.journal_lines where business_id=v_business and journal_entry_id=v_reversal_journal;
 if v_count<>2 or v_debit<>800 or v_credit<>800 then
  raise exception 'Received cheque reversal journal must balance';
 end if;
 if not exists(select 1 from public.contact_ledger_entries where business_id=v_business
  and transaction_id=v_reversal_tx and debit=800 and credit=0) then
  raise exception 'Received cheque reversal must debit customer ledger';
 end if;

 v_issued:=public.create_cheque(
  v_business,'issued',v_supplier,'CHQ-ISS-REV',null,'Bank','Main',
  '54321','Factoori','Factoori','Supplier',350,current_date,current_date+8,
  'issued then bounced','reverse-create-issued-01'
 );
 perform public.transition_cheque(
  v_business,v_issued,'cleared',current_date,v_account,'issued cleared','reverse-clear-issued-01'
 );
 select related_transaction_id into v_original_tx from public.cheques
 where business_id=v_business and id=v_issued;
 perform public.reverse_cleared_cheque(
  v_business,v_issued,current_date,'supplier cheque bounced','reverse-issued-001'
 );
 select reversal_transaction_id into v_reversal_tx from public.cheques
 where business_id=v_business and id=v_issued;
 if v_reversal_tx is null or not exists(
  select 1 from public.financial_transactions where business_id=v_business and id=v_reversal_tx
   and transaction_type='adjustment' and direction='in' and amount=350
 ) then raise exception 'Issued cheque reversal must post incoming adjustment'; end if;
 if not exists(select 1 from public.contact_ledger_entries where business_id=v_business
  and transaction_id=v_reversal_tx and debit=0 and credit=350) then
  raise exception 'Issued cheque reversal must credit supplier ledger';
 end if;

 v_failed:=false;
 perform set_config('request.jwt.claim.sub',v_outsider::text,true);
 begin
  perform public.reverse_cleared_cheque(v_business,v_received,current_date,'outsider','reverse-outsider-01');
 exception when insufficient_privilege then v_failed:=true;
 end;
 if not v_failed then raise exception 'Cross-business cheque reversal must be denied'; end if;
end;
$test$;

rollback;
