-- 033: Reverse a cleared cheque with a balanced reversing journal and immutable linkage.
begin;

alter table public.cheques
 add column if not exists reversal_transaction_id uuid;

do $constraint$
begin
 if not exists(
  select 1 from pg_constraint
  where conname='cheques_reversal_transaction_fk'
   and conrelid='public.cheques'::regclass
 ) then
  alter table public.cheques
   add constraint cheques_reversal_transaction_fk
   foreign key(business_id,reversal_transaction_id)
   references public.financial_transactions(business_id,id);
 end if;
end;
$constraint$;

create table if not exists private.financial_transaction_reversals (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 original_transaction_id uuid not null,
 reversal_transaction_id uuid not null,
 original_journal_entry_id uuid not null,
 reversal_journal_entry_id uuid not null,
 reason text not null check(length(btrim(reason)) between 1 and 500),
 idempotency_key text not null,
 request_fingerprint text not null,
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 unique(business_id,id),
 unique(business_id,original_transaction_id),
 unique(business_id,reversal_transaction_id),
 unique(business_id,idempotency_key),
 foreign key(business_id,original_transaction_id)
  references public.financial_transactions(business_id,id),
 foreign key(business_id,reversal_transaction_id)
  references public.financial_transactions(business_id,id),
 foreign key(business_id,original_journal_entry_id)
  references public.journal_entries(business_id,id),
 foreign key(business_id,reversal_journal_entry_id)
  references public.journal_entries(business_id,id)
);

alter table private.financial_transaction_reversals enable row level security;
revoke all on private.financial_transaction_reversals from public,anon,authenticated;

create or replace function public.reverse_cleared_cheque(
 p_business_id uuid,
 p_cheque_id uuid,
 p_event_date date,
 p_reason text,
 p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
 v_user uuid:=auth.uid();
 v_cheque record;
 v_original_tx record;
 v_original_journal_id uuid;
 v_reversal_tx_id uuid;
 v_reversal_journal_id uuid;
 v_event_id uuid;
 v_existing_fingerprint text;
 v_fingerprint text;
 v_period_id uuid;
 v_line_count integer:=0;
 v_ledger_count integer:=0;
 v_direction text;
 v_transaction_type text;
 v_event_key text;
begin
 if v_user is null then
  raise exception using errcode='28000',message='Authentication required';
 end if;
 if not private.has_business_permission(p_business_id,'cheques.update_status')
  or not private.has_business_permission(p_business_id,'payments.create') then
  raise exception using errcode='42501',message='Cheque reversal is not permitted';
 end if;
 if p_cheque_id is null or p_event_date is null
  or p_reason is null or length(btrim(p_reason)) not between 1 and 500
  or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 120 then
  raise exception using errcode='22023',message='Invalid cheque reversal details';
 end if;

 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text||':cheque-reversal:'||p_cheque_id::text,0));
 select * into v_cheque from public.cheques
 where business_id=p_business_id and id=p_cheque_id for update;
 if not found then
  raise exception using errcode='P0002',message='Cheque not found';
 end if;
 if v_cheque.issue_date is not null and p_event_date<v_cheque.issue_date then
  raise exception using errcode='22023',message='Reversal date cannot precede cheque issue date';
 end if;

 v_fingerprint:=md5(jsonb_build_array(
  p_business_id,p_cheque_id,p_event_date,btrim(p_reason)
 )::text);
 select id,request_fingerprint into v_event_id,v_existing_fingerprint
 from public.cheque_events
 where business_id=p_business_id and idempotency_key=p_idempotency_key;
 if v_event_id is not null then
  if v_existing_fingerprint is distinct from v_fingerprint then
   raise exception using errcode='23505',message='Cheque reversal idempotency key was used with different data';
  end if;
  return v_event_id;
 end if;

 if v_cheque.status<>'cleared' or v_cheque.related_transaction_id is null
  or v_cheque.reversal_transaction_id is not null then
  raise exception using errcode='55000',message='Only a cleared, unreversed cheque can be reversed';
 end if;

 select ft.* into v_original_tx
 from public.financial_transactions ft
 where ft.business_id=p_business_id and ft.id=v_cheque.related_transaction_id
 for update;
 if not found or v_original_tx.status<>'posted' or v_original_tx.amount<>v_cheque.amount
  or v_original_tx.contact_id<>v_cheque.contact_id
  or v_original_tx.account_id is null
  or (v_cheque.cheque_direction='received' and v_original_tx.transaction_type<>'customer_receipt')
  or (v_cheque.cheque_direction='issued' and v_original_tx.transaction_type<>'supplier_payment') then
  raise exception using errcode='55000',message='Original cheque settlement transaction is missing or inconsistent';
 end if;

 select je.id into v_original_journal_id
 from public.journal_entries je
 where je.business_id=p_business_id and je.source_type='financial_transaction'
  and je.source_id=v_original_tx.id and je.status='posted'
 order by je.created_at desc limit 1;
 if v_original_journal_id is null then
  raise exception using errcode='55000',message='Original cheque settlement journal is missing';
 end if;
 if exists(select 1 from private.financial_transaction_reversals r
  where r.business_id=p_business_id and r.original_transaction_id=v_original_tx.id) then
  raise exception using errcode='23505',message='Original cheque settlement has already been reversed';
 end if;

 select fp.id into v_period_id from public.fiscal_periods fp
 where fp.business_id=p_business_id and p_event_date between fp.date_from and fp.date_to
 order by fp.date_from desc limit 1;
 if v_period_id is not null and not exists(
  select 1 from public.fiscal_periods fp
  where fp.business_id=p_business_id and fp.id=v_period_id and fp.status in ('open','reopened')
 ) then
  raise exception using errcode='22023',message='Cheque reversal date is in a closed fiscal period';
 end if;

 v_transaction_type:=case when v_cheque.cheque_direction='received' then 'customer_refund' else 'adjustment' end;
 v_direction:=case when v_cheque.cheque_direction='received' then 'out' else 'in' end;
 v_event_key:='cheque-reversal:'||p_cheque_id::text;

 insert into public.financial_transactions(
  business_id,transaction_type,direction,amount,currency_code,transaction_date,
  account_id,contact_id,reference_number,description,status,idempotency_key,
  request_fingerprint,source_legacy_id,created_by
 ) values(
  p_business_id,v_transaction_type,v_direction,v_cheque.amount,v_original_tx.currency_code,
  p_event_date,v_original_tx.account_id,v_cheque.contact_id,v_cheque.cheque_number,
  btrim(p_reason),'posted',v_event_key,v_fingerprint,
  'cheque_reversal:'||p_cheque_id::text,v_user
 ) returning id into v_reversal_tx_id;

 insert into public.journal_entries(
  business_id,entry_date,fiscal_period_id,source_type,source_id,reverses_entry_id,description,
  status,idempotency_key,created_by
 ) values(
  p_business_id,p_event_date,v_period_id,'reversal',v_original_tx.id,v_original_journal_id,
  'برگشت چک: '||btrim(p_reason),'draft','cheque-reversal-journal:'||p_cheque_id::text,v_user
 ) returning id into v_reversal_journal_id;

 insert into public.journal_lines(
  business_id,journal_entry_id,account_id,contact_id,debit,credit,description,line_order
 )
 select jl.business_id,v_reversal_journal_id,jl.account_id,jl.contact_id,
  jl.credit,jl.debit,'برگشت: '||coalesce(jl.description,''),jl.line_order
 from public.journal_lines jl
 where jl.business_id=p_business_id and jl.journal_entry_id=v_original_journal_id;
 get diagnostics v_line_count=row_count;
 if v_line_count<2 then
  raise exception using errcode='55000',message='Original cheque settlement journal has insufficient lines to reverse';
 end if;

 update public.journal_entries
 set status='posted',posted_at=now(),posted_by=v_user,version=version+1
 where business_id=p_business_id and id=v_reversal_journal_id;

 insert into public.contact_ledger_entries(
  business_id,contact_id,entry_date,entry_type,debit,credit,transaction_id,
  description,source_legacy_id,created_by
 )
 select cle.business_id,cle.contact_id,p_event_date,
  case when v_cheque.cheque_direction='received' then 'adjustment_debit' else 'adjustment_credit' end,
  cle.credit,cle.debit,v_reversal_tx_id,'برگشت چک: '||btrim(p_reason),
  'financial_transaction:'||v_reversal_tx_id::text,v_user
 from public.contact_ledger_entries cle
 where cle.business_id=p_business_id and cle.transaction_id=v_original_tx.id;
 get diagnostics v_ledger_count=row_count;
 if v_ledger_count<>1 then
  raise exception using errcode='55000',message='Original cheque contact-ledger entry is missing or ambiguous';
 end if;

 insert into private.financial_transaction_reversals(
  business_id,original_transaction_id,reversal_transaction_id,
  original_journal_entry_id,reversal_journal_entry_id,reason,
  idempotency_key,request_fingerprint,created_by
 ) values(
  p_business_id,v_original_tx.id,v_reversal_tx_id,v_original_journal_id,
  v_reversal_journal_id,btrim(p_reason),p_idempotency_key,v_fingerprint,v_user
 );

 update public.cheques
 set status='bounced',reversal_transaction_id=v_reversal_tx_id,
  version=version+1,updated_at=now()
 where business_id=p_business_id and id=p_cheque_id;

 insert into public.cheque_events(
  business_id,cheque_id,event_type,event_date,from_status,to_status,amount,
  related_transaction_id,related_contact_id,note,idempotency_key,request_fingerprint,created_by
 ) values(
  p_business_id,p_cheque_id,'bounced',p_event_date::timestamptz,'cleared','bounced',
  v_cheque.amount,v_reversal_tx_id,v_cheque.contact_id,btrim(p_reason),
  p_idempotency_key,v_fingerprint,v_user
 ) returning id into v_event_id;

 return v_event_id;
end;
$$;

revoke all on function public.reverse_cleared_cheque(uuid,uuid,date,text,text) from public,anon;
grant execute on function public.reverse_cleared_cheque(uuid,uuid,date,text,text) to authenticated;

commit;
