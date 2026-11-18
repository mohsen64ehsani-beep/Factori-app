-- 032: Cheque lifecycle is audited; clearing posts an ordinary balanced receipt/payment.
begin;

do $test$
declare
 v_owner uuid:='c1000000-0000-4000-8000-000000000001';
 v_outsider uuid:='c1000000-0000-4000-8000-000000000002';
 v_business uuid:='c2000000-0000-4000-8000-000000000001';
 v_other_business uuid:='c2000000-0000-4000-8000-000000000002';
 v_customer uuid;
 v_supplier uuid;
 v_account uuid;
 v_received_cheque uuid;
 v_issued_cheque uuid;
 v_bounced_cheque uuid;
 v_event uuid;
 v_replay uuid;
 v_transaction uuid;
 v_failed boolean:=false;
begin
 insert into auth.users(id,email,email_confirmed_at)
 values(v_owner,'cheque-owner@example.test',now()),(v_outsider,'cheque-outsider@example.test',now())
 on conflict(id) do nothing;
 insert into public.businesses(id,name,owner_user_id)
 values(v_business,'Cheque business',v_owner),(v_other_business,'Other cheque business',v_outsider)
 on conflict(id) do nothing;
 insert into public.business_members(business_id,user_id,role_code,status,joined_at)
 values(v_business,v_owner,'owner','active',now()),(v_other_business,v_outsider,'owner','active',now())
 on conflict(business_id,user_id) do nothing;
 insert into public.contacts(business_id,contact_type,name,legacy_id)
 values(v_business,'customer','Cheque customer','cheque-customer')
 returning id into v_customer;
 insert into public.contacts(business_id,contact_type,name,legacy_id)
 values(v_business,'supplier','Cheque supplier','cheque-supplier')
 returning id into v_supplier;
 select id into v_account from public.financial_accounts
 where business_id=v_business and is_default and is_active;

 perform set_config('request.jwt.claim.sub',v_owner::text,true);
 v_received_cheque:=public.create_cheque(
  v_business,'received',v_customer,'CHQ-REC-1','1234567890123456','Bank','Main',
  '123456','Customer','Customer','Factoori',700,current_date,current_date+7,
  'received cheque','cheque-create-received-01'
 );
 v_replay:=public.create_cheque(
  v_business,'received',v_customer,'CHQ-REC-1','1234567890123456','Bank','Main',
  '123456','Customer','Customer','Factoori',700,current_date,current_date+7,
  'received cheque','cheque-create-received-01'
 );
 if v_received_cheque<>v_replay then raise exception 'Cheque creation retry must return original cheque'; end if;

 v_event:=public.transition_cheque(
  v_business,v_received_cheque,'deposited',current_date,null,'deposited to bank','cheque-deposit-001'
 );
 v_replay:=public.transition_cheque(
  v_business,v_received_cheque,'deposited',current_date,null,'deposited to bank','cheque-deposit-001'
 );
 if v_event<>v_replay then raise exception 'Cheque deposit retry must return original event'; end if;
 if (select status from public.cheques where business_id=v_business and id=v_received_cheque)<>'deposited'
  or exists(select 1 from public.financial_transactions where business_id=v_business and reference_number='CHQ-REC-1') then
  raise exception 'Depositing a cheque must not prematurely post cash';
 end if;

 v_event:=public.transition_cheque(
  v_business,v_received_cheque,'cleared',current_date,v_account,'cleared by bank','cheque-clear-received-001'
 );
 select related_transaction_id into v_transaction from public.cheques
 where business_id=v_business and id=v_received_cheque;
 if v_transaction is null or not exists(
  select 1 from public.financial_transactions where business_id=v_business and id=v_transaction
   and transaction_type='customer_receipt' and amount=700 and direction='in'
 ) then raise exception 'Cleared received cheque must post a customer receipt'; end if;
 if (select status from public.cheques where business_id=v_business and id=v_received_cheque)<>'cleared' then
  raise exception 'Received cheque status must be cleared';
 end if;

 v_issued_cheque:=public.create_cheque(
  v_business,'issued',v_supplier,'CHQ-ISS-1',null,'Bank','Main',
  '654321','Factoori','Factoori','Supplier',450,current_date,current_date+10,
  'issued cheque','cheque-create-issued-01'
 );
 perform public.transition_cheque(
  v_business,v_issued_cheque,'cleared',current_date,v_account,'issued cheque cleared','cheque-clear-issued-001'
 );
 select related_transaction_id into v_transaction from public.cheques
 where business_id=v_business and id=v_issued_cheque;
 if v_transaction is null or not exists(
  select 1 from public.financial_transactions where business_id=v_business and id=v_transaction
   and transaction_type='supplier_payment' and amount=450 and direction='out'
 ) then raise exception 'Cleared issued cheque must post a supplier payment'; end if;

 v_bounced_cheque:=public.create_cheque(
  v_business,'received',v_customer,'CHQ-BOUNCE-1',null,'Bank','Main',
  '111111','Customer','Customer','Factoori',120,current_date,current_date+5,
  'bounced cheque','cheque-create-bounced-01'
 );
 perform public.transition_cheque(
  v_business,v_bounced_cheque,'bounced',current_date,null,'bank returned cheque','cheque-bounce-001'
 );
 if (select related_transaction_id from public.cheques where business_id=v_business and id=v_bounced_cheque) is not null then
  raise exception 'Uncleared bounced cheque must not create a financial transaction';
 end if;

 v_failed:=false;
 begin
  perform public.transition_cheque(
   v_business,v_received_cheque,'bounced',current_date,null,'invalid reversal','cheque-after-clear-01'
  );
 exception when object_not_in_prerequisite_state then v_failed:=true;
 end;
 if not v_failed then raise exception 'Cleared cheque cannot be marked bounced without audited reversal'; end if;

 v_failed:=false;
 perform set_config('request.jwt.claim.sub',v_outsider::text,true);
 begin
  perform public.transition_cheque(
   v_business,v_received_cheque,'cancelled',current_date,null,'outsider','cheque-outsider-001'
  );
 exception when insufficient_privilege then v_failed:=true;
 end;
 if not v_failed then raise exception 'Cross-business cheque transition must be denied'; end if;
end;
$test$;

rollback;
