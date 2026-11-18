-- 010: Atomic financial-account transfers with balanced ledger posting.
-- DEVELOPMENT DRAFT ONLY. Depends on 001-009. Mapping must be configured before transfers.
begin;

create table if not exists public.financial_account_ledger_map (
 business_id uuid not null,
 financial_account_id uuid not null,
 chart_account_id uuid not null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 created_by uuid references auth.users(id) on delete set null,
 primary key(business_id,financial_account_id),
 foreign key(business_id,financial_account_id) references public.financial_accounts(business_id,id) on delete cascade,
 foreign key(business_id,chart_account_id) references public.chart_of_accounts(business_id,id)
);
alter table public.financial_account_ledger_map enable row level security;
revoke all on public.financial_account_ledger_map from public,anon,authenticated;

create table if not exists public.account_transfers (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 from_account_id uuid not null,
 to_account_id uuid not null,
 amount numeric(20,0) not null check(amount>0),
 currency_code text not null check(currency_code ~ '^[A-Z]{3}$'),
 transfer_date date not null,
 note text,
 status text not null default 'posted' check(status in ('posted','voided')),
 idempotency_key text not null,
 request_fingerprint text not null,
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 unique(business_id,id),
 unique(business_id,idempotency_key),
 foreign key(business_id,from_account_id) references public.financial_accounts(business_id,id),
 foreign key(business_id,to_account_id) references public.financial_accounts(business_id,id),
 check(from_account_id<>to_account_id)
);
create index if not exists account_transfers_business_date_idx
 on public.account_transfers(business_id,transfer_date desc,id);
alter table public.account_transfers enable row level security;
revoke all on public.account_transfers from public,anon,authenticated;

create or replace function public.set_financial_account_ledger_map(
 p_business_id uuid,
 p_financial_account_id uuid,
 p_chart_account_id uuid
)
returns boolean
language plpgsql security definer set search_path=''
as $$
begin
 if auth.uid() is null or not private.has_business_permission(p_business_id,'settings.manage') then
  raise exception using errcode='42501',message='Accounting mapping management is not permitted';
 end if;
 if not exists(select 1 from public.financial_accounts fa
   where fa.business_id=p_business_id and fa.id=p_financial_account_id and fa.is_active)
   or not exists(select 1 from public.chart_of_accounts ca
   where ca.business_id=p_business_id and ca.id=p_chart_account_id
     and ca.account_class='asset' and ca.is_active and ca.allow_posting) then
  raise exception using errcode='22023',message='Active financial account and posting asset ledger account are required';
 end if;
 insert into public.financial_account_ledger_map(business_id,financial_account_id,chart_account_id,created_by)
 values(p_business_id,p_financial_account_id,p_chart_account_id,auth.uid())
 on conflict(business_id,financial_account_id) do update
  set chart_account_id=excluded.chart_account_id,updated_at=now(),created_by=auth.uid();
 return true;
end;
$$;

create or replace function public.post_account_transfer(
 p_business_id uuid,
 p_from_account_id uuid,
 p_to_account_id uuid,
 p_amount numeric,
 p_transfer_date date,
 p_note text,
 p_idempotency_key text,
 p_fiscal_period_id uuid default null
)
returns uuid
language plpgsql security definer set search_path=''
as $$
declare
 v_user uuid:=auth.uid();
 v_from public.financial_accounts%rowtype;
 v_to public.financial_accounts%rowtype;
 v_from_chart uuid;
 v_to_chart uuid;
 v_transfer_id uuid;
 v_existing_fingerprint text;
 v_fingerprint text;
 v_period record;
 v_out_id uuid;
 v_in_id uuid;
 v_journal_id uuid;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required'; end if;
 if not private.has_business_permission(p_business_id,'payments.create') then
  raise exception using errcode='42501',message='Financial transfer is not permitted';
 end if;
 if p_from_account_id is null or p_to_account_id is null or p_from_account_id=p_to_account_id
   or p_amount is null or p_amount<=0 or p_amount>999999999999999999
   or trunc(p_amount)<>p_amount or p_transfer_date is null
   or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 120 then
  raise exception using errcode='22023',message='Invalid financial transfer data';
 end if;

 -- Stable row-lock ordering serializes transfers touching the same account pair.
 perform 1 from public.financial_accounts fa
 where fa.business_id=p_business_id and fa.id in (p_from_account_id,p_to_account_id)
 order by fa.id for update;
 select * into v_from from public.financial_accounts
 where business_id=p_business_id and id=p_from_account_id and is_active;
 if not found then raise exception using errcode='22023',message='Source account is missing or inactive'; end if;
 select * into v_to from public.financial_accounts
 where business_id=p_business_id and id=p_to_account_id and is_active;
 if not found then raise exception using errcode='22023',message='Destination account is missing or inactive'; end if;
 if v_from.currency_code<>v_to.currency_code then
  raise exception using errcode='22023',message='Transfers between different currencies require an exchange workflow';
 end if;
 select chart_account_id into v_from_chart from public.financial_account_ledger_map
 where business_id=p_business_id and financial_account_id=p_from_account_id for share;
 select chart_account_id into v_to_chart from public.financial_account_ledger_map
 where business_id=p_business_id and financial_account_id=p_to_account_id for share;
 if v_from_chart is null or v_to_chart is null then
  raise exception using errcode='55000',message='Map both financial accounts to active asset ledger accounts before transferring';
 end if;
 if not exists(select 1 from public.chart_of_accounts where business_id=p_business_id
   and id=v_from_chart and account_class='asset' and is_active and allow_posting for share)
   or not exists(select 1 from public.chart_of_accounts where business_id=p_business_id
   and id=v_to_chart and account_class='asset' and is_active and allow_posting for share) then
  raise exception using errcode='55000',message='Financial account ledger mapping is no longer valid';
 end if;
 if p_fiscal_period_id is not null then
  select status,date_from,date_to into v_period from public.fiscal_periods
  where business_id=p_business_id and id=p_fiscal_period_id for share;
  if not found or v_period.status<>'open' or p_transfer_date not between v_period.date_from and v_period.date_to then
   raise exception using errcode='22023',message='Fiscal period is closed or transfer date is outside the period';
  end if;
 end if;

 v_fingerprint:=md5(jsonb_build_array(p_business_id,p_from_account_id,p_to_account_id,
   p_amount::numeric(20,0),v_from.currency_code,p_transfer_date,
   nullif(btrim(coalesce(p_note,'')),''),p_fiscal_period_id)::text);
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text||':account-transfer:'||p_idempotency_key,0));
 select id,request_fingerprint into v_transfer_id,v_existing_fingerprint
 from public.account_transfers where business_id=p_business_id and idempotency_key=p_idempotency_key;
 if v_transfer_id is not null then
  if v_existing_fingerprint is distinct from v_fingerprint then
   raise exception using errcode='23505',message='Idempotency key reused with different transfer data';
  end if;
  return v_transfer_id;
 end if;

 insert into public.account_transfers(business_id,from_account_id,to_account_id,amount,currency_code,
   transfer_date,note,idempotency_key,request_fingerprint,created_by)
 values(p_business_id,p_from_account_id,p_to_account_id,p_amount::numeric(20,0),v_from.currency_code,
   p_transfer_date,nullif(btrim(coalesce(p_note,'')),''),p_idempotency_key,v_fingerprint,v_user)
 returning id into v_transfer_id;

 insert into public.financial_transactions(business_id,transaction_type,direction,amount,currency_code,
   transaction_date,account_id,description,idempotency_key,source_legacy_id,created_by)
 values(p_business_id,'account_transfer_out','out',p_amount::numeric(20,0),v_from.currency_code,
   p_transfer_date,p_from_account_id,'انتقال به حساب دیگر: '||v_to.name,
   p_idempotency_key||':out','transfer:'||v_transfer_id::text||':out',v_user) returning id into v_out_id;
 insert into public.financial_transactions(business_id,transaction_type,direction,amount,currency_code,
   transaction_date,account_id,description,idempotency_key,source_legacy_id,created_by)
 values(p_business_id,'account_transfer_in','in',p_amount::numeric(20,0),v_to.currency_code,
   p_transfer_date,p_to_account_id,'انتقال از حساب دیگر: '||v_from.name,
   p_idempotency_key||':in','transfer:'||v_transfer_id::text||':in',v_user) returning id into v_in_id;

 insert into public.journal_entries(business_id,entry_date,fiscal_period_id,source_type,source_id,
   description,status,idempotency_key,created_by)
 values(p_business_id,p_transfer_date,p_fiscal_period_id,'financial_transaction',v_transfer_id,
   coalesce(nullif(btrim(coalesce(p_note,'')),''),'انتقال بین حساب‌ها'),'draft',
   'account-transfer:'||p_idempotency_key,v_user)
 returning id into v_journal_id;
 insert into public.journal_lines(business_id,journal_entry_id,account_id,debit,credit,description,line_order)
 values
  (p_business_id,v_journal_id,v_to_chart,p_amount::numeric(20,0),0,'افزایش موجودی حساب مقصد',1),
  (p_business_id,v_journal_id,v_from_chart,0,p_amount::numeric(20,0),'کاهش موجودی حساب مبدأ',2);
 update public.journal_entries set status='posted',posted_at=now(),posted_by=v_user,version=version+1
 where business_id=p_business_id and id=v_journal_id;
 return v_transfer_id;
end;
$$;

revoke all on function public.set_financial_account_ledger_map(uuid,uuid,uuid) from public,anon;
revoke all on function public.post_account_transfer(uuid,uuid,uuid,numeric,date,text,text,uuid) from public,anon;
grant execute on function public.set_financial_account_ledger_map(uuid,uuid,uuid) to authenticated;
grant execute on function public.post_account_transfer(uuid,uuid,uuid,numeric,date,text,text,uuid) to authenticated;

commit;
