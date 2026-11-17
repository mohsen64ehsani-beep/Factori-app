-- 004a: Shared offline-sync infrastructure and server-enforced free-tier quotas.
-- DEVELOPMENT DRAFT ONLY. Apply after 001 and before 005 in disposable staging.
begin;

create table if not exists public.sync_devices (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 user_id uuid not null,
 device_name text not null check(length(btrim(device_name)) between 1 and 120),
 platform text not null check(platform in ('android','web','ios','other')),
 device_public_key jsonb,
 status text not null default 'active' check(status in ('active','revoked')),
 last_seen_at timestamptz,
 created_at timestamptz not null default now(),
 revoked_at timestamptz,
 unique(business_id,id),
 foreign key(business_id,user_id) references public.business_members(business_id,user_id) on delete cascade,
 check(device_public_key is null or jsonb_typeof(device_public_key)='object')
);
create index if not exists sync_devices_member_idx on public.sync_devices(business_id,user_id,status);

create table if not exists public.sync_cursors (
 business_id uuid not null,
 device_id uuid not null,
 last_revision bigint not null default 0 check(last_revision>=0),
 last_synced_at timestamptz,
 primary key(business_id,device_id),
 foreign key(business_id,device_id) references public.sync_devices(business_id,id) on delete cascade
);

create table if not exists public.sync_operations (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null,
 device_id uuid not null,
 operation_id uuid not null,
 request_fingerprint text,
 operation_type text not null check(operation_type in ('upsert','delete')),
 record_type text not null,
 record_id uuid,
 base_version bigint,
 result_version bigint,
 status text not null check(status in ('applied','conflict','rejected')),
 result_payload jsonb,
 created_at timestamptz not null default now(),
 unique(business_id,id),
 unique(business_id,device_id,operation_id),
 foreign key(business_id,device_id) references public.sync_devices(business_id,id) on delete cascade
);
create index if not exists sync_operations_record_idx on public.sync_operations(business_id,record_type,record_id,created_at desc);
alter table public.sync_operations add column if not exists request_fingerprint text;

create table if not exists public.record_revisions (
 id bigint generated always as identity primary key,
 business_id uuid not null references public.businesses(id) on delete cascade,
 record_type text not null,
 record_id uuid not null,
 revision bigint not null check(revision>0),
 changed_by uuid references auth.users(id) on delete set null,
 change_type text not null check(change_type in ('upsert','delete')),
 change_payload jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now(),
 unique(business_id,revision)
);
create index if not exists record_revisions_business_cursor_idx on public.record_revisions(business_id,revision);
create index if not exists record_revisions_record_idx on public.record_revisions(business_id,record_id,revision desc);

create table if not exists public.business_feature_limits (
 business_id uuid not null references public.businesses(id) on delete cascade,
 feature_code text not null,
 limit_value integer check(limit_value is null or limit_value>=0),
 period_type text not null check(period_type in ('daily','lifetime','per_record')),
 enabled boolean not null default true,
 updated_at timestamptz not null default now(),
 updated_by uuid references auth.users(id) on delete set null,
 primary key(business_id,feature_code)
);
create table if not exists public.business_feature_usage (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 feature_code text not null,
 usage_date date not null,
 operation_id uuid not null,
 created_at timestamptz not null default now(),
 unique(business_id,feature_code,usage_date,operation_id)
);
create index if not exists business_feature_usage_count_idx on public.business_feature_usage(business_id,feature_code,usage_date);

alter table public.sync_devices enable row level security;
alter table public.sync_cursors enable row level security;
alter table public.sync_operations enable row level security;
alter table public.record_revisions enable row level security;
alter table public.business_feature_limits enable row level security;
alter table public.business_feature_usage enable row level security;
revoke all on public.sync_devices,public.sync_cursors,public.sync_operations,
 public.record_revisions,public.business_feature_limits,public.business_feature_usage
 from public,anon,authenticated;

create or replace function private.seed_business_feature_limits()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
 insert into public.business_feature_limits(business_id,feature_code,limit_value,period_type)
 values
  (new.id,'invoices.daily_limit',3,'daily'),
  (new.id,'invoice.items.limit',10,'per_record'),
  (new.id,'customers.total_limit',50,'lifetime'),
  (new.id,'products.total_limit',50,'lifetime'),
  (new.id,'services.total_limit',50,'lifetime'),
  (new.id,'warehouses.total_limit',1,'lifetime')
 on conflict(business_id,feature_code) do nothing;
 return new;
end;
$$;
drop trigger if exists businesses_seed_feature_limits on public.businesses;
create trigger businesses_seed_feature_limits after insert on public.businesses
for each row execute function private.seed_business_feature_limits();

insert into public.business_feature_limits(business_id,feature_code,limit_value,period_type)
select b.id,x.feature_code,x.limit_value,x.period_type
from public.businesses b
cross join (values
 ('invoices.daily_limit',3,'daily'),
 ('invoice.items.limit',10,'per_record'),
 ('customers.total_limit',50,'lifetime'),
 ('products.total_limit',50,'lifetime'),
 ('services.total_limit',50,'lifetime'),
 ('warehouses.total_limit',1,'lifetime')
) as x(feature_code,limit_value,period_type)
on conflict(business_id,feature_code) do nothing;

create or replace function private.assert_feature_limit(p_business_id uuid,p_feature_code text,p_requested integer)
returns void language plpgsql security definer set search_path=''
as $$
declare v_limit integer; v_period text; v_current bigint:=0; v_collection text;
begin
 if auth.uid() is null or not private.is_business_member(p_business_id) then
  raise exception using errcode='42501',message='Business access denied';
 end if;
 if p_requested is null or p_requested<0 then
  raise exception using errcode='22023',message='Invalid requested feature quantity';
 end if;
 select limit_value,period_type into v_limit,v_period
 from public.business_feature_limits
 where business_id=p_business_id and feature_code=p_feature_code and enabled
 for update;
 if not found then raise exception using errcode='55000',message='Feature entitlement is not configured'; end if;
 if v_limit is null then return; end if;
 if v_period='per_record' then
  if p_requested>v_limit then raise exception using errcode='54000',message='Per-record feature limit exceeded'; end if;
  return;
 end if;
 v_collection:=case p_feature_code
  when 'customers.total_limit' then 'cust'
  when 'products.total_limit' then 'prod'
  when 'services.total_limit' then 'services'
  when 'warehouses.total_limit' then 'warehouses'
  else null end;
 if v_collection is not null then
  execute 'select count(*) from private.business_state_records where business_id=$1 and collection=$2 and deleted_at is null'
   into v_current using p_business_id,v_collection;
  if v_current+p_requested>v_limit then
   raise exception using errcode='54000',message='Business feature limit exceeded';
  end if;
  return;
 end if;
 if p_requested>v_limit then raise exception using errcode='54000',message='Feature limit exceeded'; end if;
end;
$$;

create or replace function private.consume_feature_quota(p_business_id uuid,p_feature_code text,p_usage_date date,p_operation_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare v_limit integer; v_period text; v_count bigint; v_inserted uuid;
begin
 if auth.uid() is null or not private.is_business_member(p_business_id) then
  raise exception using errcode='42501',message='Business access denied';
 end if;
 if p_usage_date is null or p_operation_id is null then
  raise exception using errcode='22023',message='Quota date and operation ID are required';
 end if;
 select limit_value,period_type into v_limit,v_period
 from public.business_feature_limits
 where business_id=p_business_id and feature_code=p_feature_code and enabled
 for update;
 if not found then raise exception using errcode='55000',message='Feature entitlement is not configured'; end if;
 if v_period<>'daily' then raise exception using errcode='22023',message='Feature does not use a daily quota'; end if;
 if v_limit is null then return; end if;
 insert into public.business_feature_usage(business_id,feature_code,usage_date,operation_id)
 values(p_business_id,p_feature_code,p_usage_date,p_operation_id)
 on conflict(business_id,feature_code,usage_date,operation_id) do nothing
 returning id into v_inserted;
 if v_inserted is null then return; end if;
 select count(*) into v_count from public.business_feature_usage
 where business_id=p_business_id and feature_code=p_feature_code and usage_date=p_usage_date;
 if v_count>v_limit then raise exception using errcode='54000',message='Daily feature quota exceeded'; end if;
end;
$$;

revoke all on function private.seed_business_feature_limits() from public,anon,authenticated;
revoke all on function private.assert_feature_limit(uuid,text,integer) from public,anon,authenticated;
revoke all on function private.consume_feature_quota(uuid,text,date,uuid) from public,anon,authenticated;

commit;
