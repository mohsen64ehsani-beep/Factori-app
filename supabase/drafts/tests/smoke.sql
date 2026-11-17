-- Synthetic smoke tests. Run only against the disposable PostgreSQL CI database.
\set ON_ERROR_STOP on

insert into auth.users(id) values
('11111111-1111-4111-8111-111111111111'),
('22222222-2222-4222-8222-222222222222'),
('33333333-3333-4333-8333-333333333333')
on conflict do nothing;

set role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false);
select public.create_business('Factoori Smoke A') as business_a \gset
reset role;

set role authenticated;
select set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',false);
select public.create_business('Factoori Smoke B') as business_b \gset
reset role;

insert into public.profiles(id,display_name)
values ('33333333-3333-4333-8333-333333333333','Sales Test')
on conflict(id) do nothing;

insert into public.business_members(business_id,user_id,role_code,status,joined_at)
values (:'business_a'::uuid,'33333333-3333-4333-8333-333333333333','sales','active',now());

insert into public.documents(
  business_id,document_type,document_number,document_date,status,posted_at,total_amount,currency_code
) values
(:'business_a'::uuid,'sale','S-1',current_date,'posted',now(),10000,'IRR'),
(:'business_a'::uuid,'purchase','P-1',current_date,'posted',now(),20000,'IRR');

select set_config('test.business_a',:'business_a',false);
select set_config('test.business_b',:'business_b',false);

-- Owner A must not see Business B.
set role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false);
do $$
declare a uuid := current_setting('test.business_a')::uuid; b uuid := current_setting('test.business_b')::uuid;
begin
  if (select count(*) from public.businesses where id=a) <> 1 then
    raise exception 'owner cannot read own business';
  end if;
  if (select count(*) from public.businesses where id=b) <> 0 then
    raise exception 'cross-business isolation failed';
  end if;
  if not exists (
    select 1 from public.get_business_entitlements(a)
    where feature_code='invoices.daily_limit' and enabled and limit_value=2
  ) then
    raise exception 'free plan entitlements missing';
  end if;
  if has_table_privilege('authenticated','private.product_costs','SELECT') then
    raise exception 'private product cost table is exposed';
  end if;
end
$$;
reset role;

-- Sales role can read a sale but must not read purchase documents.
set role authenticated;
select set_config('request.jwt.claim.sub','33333333-3333-4333-8333-333333333333',false);
do $$
declare a uuid := current_setting('test.business_a')::uuid;
begin
  if (select count(*) from public.documents where business_id=a and document_type='sale') <> 1 then
    raise exception 'sales role cannot read sales document';
  end if;
  if (select count(*) from public.documents where business_id=a and document_type='purchase') <> 0 then
    raise exception 'sales role can read purchase document';
  end if;
  if has_table_privilege('authenticated','private.document_item_costs','SELECT') then
    raise exception 'private document cost table is exposed';
  end if;
end
$$;
reset role;

-- Quota helper is internal-only; run as postgres while retaining the owner JWT claim.
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false);
do $$
declare
  a uuid := current_setting('test.business_a')::uuid;
  n bigint;
begin
  n := private.consume_feature_quota(a,'invoices.daily_limit',current_date,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  if n <> 1 then raise exception 'first quota use should be 1'; end if;
  n := private.consume_feature_quota(a,'invoices.daily_limit',current_date,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  if n <> 1 then raise exception 'idempotent retry consumed quota twice'; end if;
  n := private.consume_feature_quota(a,'invoices.daily_limit',current_date,'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
  if n <> 2 then raise exception 'second quota use should be 2'; end if;
  begin
    perform private.consume_feature_quota(a,'invoices.daily_limit',current_date,'cccccccc-cccc-4ccc-8ccc-cccccccccccc');
    raise exception 'expected daily quota limit error';
  exception when check_violation then
    null;
  end;
end
$$;
