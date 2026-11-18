-- 032: Audited cheque creation and lifecycle transitions with settlement posting.
-- Cleared cheques create the same normalized receipt/payment as ordinary transactions.
begin;

alter table public.cheques add column if not exists idempotency_key text;
alter table public.cheques add column if not exists request_fingerprint text;
create unique index if not exists cheques_business_idempotency_unique
 on public.cheques(business_id,idempotency_key) where idempotency_key is not null;

alter table public.cheque_events add column if not exists idempotency_key text;
alter table public.cheque_events add column if not exists request_fingerprint text;
create unique index if not exists cheque_events_business_idempotency_unique
 on public.cheque_events(business_id,idempotency_key) where idempotency_key is not null;

create or replace function public.create_cheque(
 p_business_id uuid,
 p_cheque_direction text,
 p_contact_id uuid,
 p_cheque_number text,
 p_sayad_id text,
 p_bank_name text,
 p_branch_name text,
 p_account_number text,
 p_account_holder text,
 p_drawer_name text,
 p_payee_name text,
 p_amount numeric,
 p_issue_date date,
 p_due_date date,
 p_note text,
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
 v_cheque_id uuid;
 v_existing_fingerprint text;
 v_fingerprint text;
 v_event_key text;
begin
 if v_user is null then
  raise exception using errcode='28000',message='Authentication required';
 end if;
 if not private.has_business_permission(p_business_id,'payments.create')
  or not private.has_business_permission(p_business_id,'cheques.update_status') then
  raise exception using errcode='42501',message='Cheque creation is not permitted';
 end if;
 if p_cheque_direction not in ('received','issued')
  or p_contact_id is null
  or p_amount is null or p_amount::text in ('NaN','Infinity','-Infinity')
  or p_amount<=0 or trunc(p_amount)<>p_amount or p_amount>999999999999999999
  or length(btrim(coalesce(p_cheque_number,''))) not between 1 and 80
  or p_due_date is null
  or (p_issue_date is not null and p_due_date<p_issue_date)
  or (nullif(btrim(coalesce(p_sayad_id,'')),'') is not null
      and btrim(p_sayad_id) !~ '^[0-9]{16}$')
  or length(btrim(coalesce(p_bank_name,'')))>120
  or length(btrim(coalesce(p_branch_name,'')))>120
  or length(btrim(coalesce(p_account_number,'')))>80
  or length(btrim(coalesce(p_account_holder,'')))>160
  or length(btrim(coalesce(p_drawer_name,'')))>160
  or length(btrim(coalesce(p_payee_name,'')))>160
  or length(btrim(coalesce(p_note,'')))>500
  or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 120 then
  raise exception using errcode='22023',message='Invalid cheque details';
 end if;

 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text||':cheque-create:'||p_idempotency_key,0));
 v_fingerprint:=md5(jsonb_build_array(
  p_business_id,p_cheque_direction,p_contact_id,btrim(p_cheque_number),
  nullif(btrim(coalesce(p_sayad_id,'')),''),nullif(btrim(coalesce(p_bank_name,'')),''),
  nullif(btrim(coalesce(p_branch_name,'')),''),nullif(btrim(coalesce(p_account_number,'')),''),
  nullif(btrim(coalesce(p_account_holder,'')),''),nullif(btrim(coalesce(p_drawer_name,'')), ''),
  nullif(btrim(coalesce(p_payee_name,'')),''),p_amount,p_issue_date,p_due_date,
  nullif(btrim(coalesce(p_note,'')),'')
 )::text);

 select id,request_fingerprint into v_cheque_id,v_existing_fingerprint
 from public.cheques where business_id=p_business_id and idempotency_key=p_idempotency_key;
 if v_cheque_id is not null then
  if v_existing_fingerprint is distinct from v_fingerprint then
   raise exception using errcode='23505',message='Cheque idempotency key was already used with different data';
  end if;
  return v_cheque_id;
 end if;

 if not exists(
  select 1 from public.contacts c
  where c.business_id=p_business_id and c.id=p_contact_id and c.is_active
   and ((p_cheque_direction='received' and c.contact_type in ('customer','both'))
     or (p_cheque_direction='issued' and c.contact_type in ('supplier','both')))
 ) then
  raise exception using errcode='22023',message='Cheque contact is missing, inactive, or has an incompatible role';
 end if;

 select coalesce(bs.currency_code,'IRR') into v_currency
 from public.business_settings bs where bs.business_id=p_business_id;
 v_currency:=coalesce(v_currency,'IRR');

 insert into public.cheques(
  business_id,cheque_direction,cheque_number,sayad_id,bank_name,branch_name,
  account_number,account_holder,drawer_name,payee_name,amount,currency_code,
  issue_date,due_date,status,contact_id,note,idempotency_key,request_fingerprint,created_by
 ) values(
  p_business_id,p_cheque_direction,btrim(p_cheque_number),
  nullif(btrim(coalesce(p_sayad_id,'')),''),
  nullif(btrim(coalesce(p_bank_name,'')),''),
  nullif(btrim(coalesce(p_branch_name,'')),''),
  nullif(btrim(coalesce(p_account_number,'')),''),
  nullif(btrim(coalesce(p_account_holder,'')),''),
  nullif(btrim(coalesce(p_drawer_name,'')),''),
  nullif(btrim(coalesce(p_payee_name,'')),''),
  p_amount,v_currency,p_issue_date,p_due_date,'pending',p_contact_id,
  nullif(btrim(coalesce(p_note,'')),''),p_idempotency_key,v_fingerprint,v_user
 ) returning id into v_cheque_id;

 v_event_key:='cheque-create:'||p_idempotency_key;
 insert into public.cheque_events(
  business_id,cheque_id,event_type,event_date,from_status,to_status,amount,
  related_contact_id,note,idempotency_key,request_fingerprint,created_by
 ) values(
  p_business_id,v_cheque_id,'created',now(),null,'pending',p_amount,
  p_contact_id,nullif(btrim(coalesce(p_note,'')),''),v_event_key,v_fingerprint,v_user
 );
 return v_cheque_id;
end;
$$;

create or replace function public.transition_cheque(
 p_business_id uuid,
 p_cheque_id uuid,
 p_to_status text,
 p_event_date date,
 p_financial_account_id uuid,
 p_note text,
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
 if p_cheque_id is null or p_to_status not in ('deposited','cleared','bounced','cancelled','returned')
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

 v_fingerprint:=md5(jsonb_build_array(
  p_business_id,p_cheque_id,v_cheque.status,p_to_status,p_event_date,
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
    p_event_date,null,0,v_cheque.cheque_number,
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
$$;

revoke all on function public.create_cheque(uuid,text,uuid,text,text,text,text,text,text,text,text,numeric,date,date,text,text) from public,anon;
revoke all on function public.transition_cheque(uuid,uuid,text,date,uuid,text,text) from public,anon;
grant execute on function public.create_cheque(uuid,text,uuid,text,text,text,text,text,text,text,text,numeric,date,date,text,text) to authenticated;
grant execute on function public.transition_cheque(uuid,uuid,text,date,uuid,text,text) to authenticated;

commit;
