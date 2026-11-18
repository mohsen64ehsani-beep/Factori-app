-- 016: Seed a usable chart of accounts and a default financial account for every business.
-- DEVELOPMENT DRAFT ONLY. This does not create balances or post accounting entries.
begin;

create or replace function private.ensure_business_accounting_defaults(p_business_id uuid)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  v_currency text;
  v_default_account_id uuid;
begin
  if p_business_id is null or not exists(select 1 from public.businesses where id=p_business_id) then
    raise exception using errcode='22023',message='Business does not exist';
  end if;

  select coalesce(currency_code,'IRR') into v_currency
  from public.business_settings where business_id=p_business_id;
  v_currency:=coalesce(v_currency,'IRR');

  insert into public.chart_of_accounts(business_id,code,name,account_class,is_system,is_active,allow_posting)
  values
    (p_business_id,'1000','صندوق نقدی','asset',true,true,true),
    (p_business_id,'1010','حساب‌های بانکی','asset',true,true,true),
    (p_business_id,'1020','کیف پول و درگاه','asset',true,true,true),
    (p_business_id,'1030','وجوه در راه','asset',true,true,true),
    (p_business_id,'1100','حساب‌های دریافتنی اشخاص','asset',true,true,true),
    (p_business_id,'1200','موجودی کالا','asset',true,true,true),
    (p_business_id,'2000','حساب‌های پرداختنی اشخاص','liability',true,true,true),
    (p_business_id,'2100','مالیات و عوارض پرداختنی','liability',true,true,true),
    (p_business_id,'3000','سرمایه مالک','equity',true,true,true),
    (p_business_id,'4000','درآمد فروش کالا','income',true,true,true),
    (p_business_id,'4100','درآمد خدمات','income',true,true,true),
    (p_business_id,'5000','بهای تمام‌شده کالای فروش‌رفته','expense',true,true,true),
    (p_business_id,'5100','هزینه مستقیم خدمات','expense',true,true,true),
    (p_business_id,'6000','هزینه‌های عملیاتی','expense',true,true,true),
    (p_business_id,'7000','سایر درآمدها','income',true,true,true)
  on conflict(business_id,code) do nothing;

  insert into public.financial_accounts(business_id,name,account_type,currency_code,is_active,is_default,
    opening_balance,legacy_id)
  select p_business_id,'صندوق نقدی','cash',v_currency,true,true,0,'factoori:system-default-cash:v1'
  where not exists(
    select 1 from public.financial_accounts fa
    where fa.business_id=p_business_id and fa.is_active and fa.is_default
  )
  on conflict(business_id,legacy_id) do nothing;

  select fa.id into v_default_account_id
  from public.financial_accounts fa
  where fa.business_id=p_business_id and fa.is_active and fa.is_default
  order by fa.created_at,fa.id
  limit 1;

  -- Map all active financial accounts by their explicit type. Existing mappings
  -- are never overwritten automatically.
  insert into public.financial_account_ledger_map(business_id,financial_account_id,chart_account_id)
  select fa.business_id,fa.id,coa.id
  from public.financial_accounts fa
  join public.chart_of_accounts coa
    on coa.business_id=fa.business_id
   and coa.code=case fa.account_type
     when 'cash' then '1000'
     when 'bank' then '1010'
     when 'wallet' then '1020'
     when 'clearing' then '1030'
   end
  where fa.business_id=p_business_id and fa.is_active
  on conflict(business_id,financial_account_id) do nothing;

  if v_default_account_id is null then
    raise exception using errcode='23514',message='Business has no active default financial account';
  end if;
end;
$$;

create or replace function private.bootstrap_business_accounting_defaults()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  perform private.ensure_business_accounting_defaults(new.id);
  return new;
end;
$$;

revoke all on function private.ensure_business_accounting_defaults(uuid) from public,anon,authenticated;
revoke all on function private.bootstrap_business_accounting_defaults() from public,anon,authenticated;

drop trigger if exists businesses_bootstrap_accounting_defaults on public.businesses;
create trigger businesses_bootstrap_accounting_defaults
after insert on public.businesses
for each row execute function private.bootstrap_business_accounting_defaults();

-- Backfill businesses created before this migration without changing any balance.
select private.ensure_business_accounting_defaults(id) from public.businesses;

commit;
