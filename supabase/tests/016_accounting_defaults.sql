-- 016: default chart/account provisioning and tenant isolation.
begin;

do $test$
declare
  v_owner uuid:='86000000-0000-4000-8000-000000000001';
  v_business_a uuid:='87000000-0000-4000-8000-000000000001';
  v_business_b uuid:='87000000-0000-4000-8000-000000000002';
  v_account_a uuid;
  v_account_b uuid;
  v_count integer;
begin
  insert into auth.users(id,email,email_confirmed_at)
  values(v_owner,'accounting-defaults@example.test',now())
  on conflict(id) do nothing;

  insert into public.businesses(id,name,owner_user_id)
  values
    (v_business_a,'Accounting defaults A',v_owner),
    (v_business_b,'Accounting defaults B',v_owner)
  on conflict(id) do nothing;

  select id into v_account_a from public.financial_accounts
  where business_id=v_business_a and is_default and is_active;
  select id into v_account_b from public.financial_accounts
  where business_id=v_business_b and is_default and is_active;

  if v_account_a is null or v_account_b is null or v_account_a=v_account_b then
    raise exception 'Each business must receive its own default cash account';
  end if;

  select count(*) into v_count from public.chart_of_accounts
  where business_id=v_business_a and is_system and code in
    ('1000','1010','1020','1030','1100','1200','1300','2000','2100','2200','3000','4000','4100','5000','5100','6000','7000');
  if v_count<>17 then raise exception 'Expected 17 default chart accounts, got %',v_count; end if;

  if not exists(
    select 1 from public.financial_account_ledger_map m
    join public.chart_of_accounts c on c.business_id=m.business_id and c.id=m.chart_account_id
    where m.business_id=v_business_a and m.financial_account_id=v_account_a and c.code='1000'
  ) then raise exception 'Default cash account must map to the cash ledger account'; end if;

  if exists(
    select 1 from public.financial_account_ledger_map m
    join public.chart_of_accounts c on c.business_id=m.business_id and c.id=m.chart_account_id
    where m.business_id=v_business_a and c.business_id<>v_business_a
  ) then raise exception 'Financial account mapping crossed business boundary'; end if;

  if (select opening_balance from public.financial_accounts where business_id=v_business_a and id=v_account_a)<>0 then
    raise exception 'Default account must not invent an opening balance';
  end if;

  -- Calling the private initializer again must be idempotent.
  perform private.ensure_business_accounting_defaults(v_business_a);
  if (select count(*) from public.financial_accounts where business_id=v_business_a and is_default and is_active)<>1 then
    raise exception 'Default account initialization must be idempotent';
  end if;
end;
$test$;

rollback;
