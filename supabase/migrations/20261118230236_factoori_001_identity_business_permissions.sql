-- 001: Factoori shared identity, business tenancy, and permission foundation.
-- DEVELOPMENT DRAFT ONLY. Do not apply to production until reviewed and approved.
begin;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  avatar_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.businesses (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 2 and 160),
  owner_user_id uuid not null references auth.users(id) on delete restrict,
  status text not null default 'active' check (status in ('active','suspended','archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version bigint not null default 1 check (version > 0)
);

create table if not exists public.permission_catalog (
  code text primary key check (code ~ '^[a-z][a-z0-9_.-]{1,100}$'),
  description text not null,
  is_sensitive boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.business_members (
  business_id uuid not null references public.businesses(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role_code text not null check (role_code in ('owner','admin','accountant','sales','viewer')),
  status text not null default 'active' check (status in ('invited','active','suspended','removed')),
  invited_by uuid references auth.users(id) on delete set null,
  joined_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (business_id,user_id)
);
create index if not exists business_members_user_status_idx
  on public.business_members(user_id,status,business_id);

create table if not exists public.business_role_permissions (
  role_code text not null check (role_code in ('owner','admin','accountant','sales','viewer')),
  permission_code text not null references public.permission_catalog(code) on delete cascade,
  allowed boolean not null,
  primary key (role_code,permission_code)
);

create table if not exists public.business_member_permission_overrides (
  business_id uuid not null,
  user_id uuid not null,
  permission_code text not null references public.permission_catalog(code) on delete cascade,
  allowed boolean not null,
  reason text,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (business_id,user_id,permission_code),
  foreign key (business_id,user_id)
    references public.business_members(business_id,user_id) on delete cascade
);

create table if not exists public.business_settings (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  currency_code text not null default 'IRR' check (currency_code ~ '^[A-Z]{3}$'),
  currency_scale smallint not null default 1 check (currency_scale in (1,10,100,1000,10000)),
  timezone text not null default 'Asia/Tehran',
  date_calendar text not null default 'jalali' check (date_calendar in ('jalali','gregorian')),
  costing_method text not null default 'weighted_average' check (costing_method in ('weighted_average','fifo')),
  tax_enabled boolean not null default false,
  default_tax_rate numeric(7,4) not null default 0 check (default_tax_rate between 0 and 100),
  negative_stock_allowed boolean not null default false,
  settings_json jsonb not null default '{}'::jsonb check (jsonb_typeof(settings_json)='object'),
  updated_at timestamptz not null default now()
);

insert into public.permission_catalog(code,description,is_sensitive) values
 ('business.read','Read business profile',false),
 ('business.settings.manage','Manage business settings',false),
 ('members.read','Read business members',false),
 ('members.manage','Invite, suspend and manage members',false),
 ('contacts.read','Read contacts',false),
 ('contacts.write','Create and edit contacts',false),
 ('catalog.read','Read products and services',false),
 ('catalog.write','Create and edit products and services',false),
 ('catalog.cost.read','Read purchase costs and cost snapshots',true),
 ('sales.read','Read sales documents',false),
 ('sales.create','Create sales drafts',false),
 ('sales.edit_draft','Edit own or permitted draft sales documents',false),
 ('sales.post','Post sales documents',false),
 ('sales.void','Void posted sales documents through reversal workflow',false),
 ('purchases.read','Read purchase documents',false),
 ('purchases.create','Create purchase documents',false),
 ('purchases.post','Post purchase documents',false),
 ('payments.read','Read financial transactions',false),
 ('payments.create','Create financial transactions',false),
 ('cheques.read','Read cheque records',false),
 ('cheques.update_status','Update cheque lifecycle through validated actions',false),
 ('inventory.read','Read inventory balances and movements',false),
 ('inventory.adjust','Adjust inventory through controlled operations',false),
 ('inventory.transfer','Transfer stock between warehouses',false),
 ('expenses.read','Read expenses',false),
 ('expenses.create','Create expenses',false),
 ('reports.basic.read','Read operational reports',false),
 ('reports.profit.read','Read margin and profit reports',true),
 ('settings.manage','Manage application settings',false),
 ('audit.read','Read business audit log',false)
on conflict(code) do update set description=excluded.description,is_sensitive=excluded.is_sensitive;

-- Conservative defaults. Owner is handled as an explicit special case by the
-- permission function; admin defaults are broad but do not grant owner transfer.
insert into public.business_role_permissions(role_code,permission_code,allowed)
select roles.role_code, p.code,
 case
  when roles.role_code='owner' then true
  when roles.role_code='admin' then p.code not in ('audit.read')
  when roles.role_code='accountant' then p.code in (
   'business.read','members.read','contacts.read','contacts.write','catalog.read',
   'catalog.write','catalog.cost.read','sales.read','sales.create','sales.edit_draft',
   'sales.post','purchases.read','purchases.create','purchases.post','payments.read',
   'payments.create','cheques.read','cheques.update_status','inventory.read',
   'inventory.adjust','inventory.transfer','expenses.read','expenses.create',
   'reports.basic.read','reports.profit.read','audit.read')
  when roles.role_code='sales' then p.code in (
   'business.read','contacts.read','contacts.write','catalog.read','sales.read',
   'sales.create','sales.edit_draft','inventory.read','reports.basic.read')
  else p.code in ('business.read','contacts.read','catalog.read','sales.read','reports.basic.read')
 end
from (values ('owner'),('admin'),('accountant'),('sales'),('viewer')) as roles(role_code)
cross join public.permission_catalog p
on conflict(role_code,permission_code) do nothing;

insert into public.permission_catalog(code,description,is_sensitive) values
 ('invoice.settings.read','Read bank details and invoice printing settings',true),
 ('settings.read','Read non-sensitive business settings',false),
 ('contacts.ledger.read','Read financial balances and contact ledger',true)
on conflict(code) do nothing;

insert into public.business_role_permissions(role_code,permission_code,allowed)
values
 ('owner','invoice.settings.read',true),('admin','invoice.settings.read',true),
 ('accountant','invoice.settings.read',true),('sales','invoice.settings.read',true),
 ('viewer','invoice.settings.read',false),
 ('owner','settings.read',true),('admin','settings.read',true),
 ('accountant','settings.read',true),('sales','settings.read',false),
 ('viewer','settings.read',false),
 ('owner','contacts.ledger.read',true),('admin','contacts.ledger.read',true),
 ('accountant','contacts.ledger.read',true),('sales','contacts.ledger.read',false),
 ('viewer','contacts.ledger.read',false)
on conflict(role_code,permission_code) do nothing;

create or replace function private.is_business_member(p_business_id uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.business_members m
    join public.businesses b on b.id=m.business_id
    where m.business_id=p_business_id
      and m.user_id=auth.uid()
      and m.status='active'
      and b.status='active'
  );
$$;

create or replace function private.has_business_permission(p_business_id uuid,p_permission_code text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select coalesce((
    select case
      when m.role_code='owner' then true
      else coalesce(o.allowed,rp.allowed,false)
    end
    from public.business_members m
    join public.businesses b on b.id=m.business_id
    left join public.business_member_permission_overrides o
      on o.business_id=m.business_id and o.user_id=m.user_id
      and o.permission_code=p_permission_code
    left join public.business_role_permissions rp
      on rp.role_code=m.role_code and rp.permission_code=p_permission_code
    where m.business_id=p_business_id and m.user_id=auth.uid()
      and m.status='active' and b.status='active'
    limit 1
  ),false);
$$;

create or replace function private.is_business_owner(p_business_id uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.business_members m
    where m.business_id=p_business_id and m.user_id=auth.uid()
      and m.role_code='owner' and m.status='active'
  );
$$;

create or replace function private.touch_updated_at()
returns trigger language plpgsql set search_path=''
as $$ begin new.updated_at=now(); return new; end $$;

drop trigger if exists profiles_touch_updated_at on public.profiles;
create trigger profiles_touch_updated_at before update on public.profiles
for each row execute function private.touch_updated_at();
drop trigger if exists businesses_touch_updated_at on public.businesses;
create trigger businesses_touch_updated_at before update on public.businesses
for each row execute function private.touch_updated_at();
drop trigger if exists business_members_touch_updated_at on public.business_members;
create trigger business_members_touch_updated_at before update on public.business_members
for each row execute function private.touch_updated_at();
drop trigger if exists business_settings_touch_updated_at on public.business_settings;
create trigger business_settings_touch_updated_at before update on public.business_settings
for each row execute function private.touch_updated_at();
drop trigger if exists member_overrides_touch_updated_at on public.business_member_permission_overrides;
create trigger member_overrides_touch_updated_at before update on public.business_member_permission_overrides
for each row execute function private.touch_updated_at();

create or replace function private.handle_new_auth_user()
returns trigger language plpgsql security definer
set search_path=''
as $$
begin
  insert into public.profiles(id,display_name)
  values(new.id,coalesce(nullif(btrim(new.raw_user_meta_data->>'display_name'),''),split_part(coalesce(new.email,''),'@',1)))
  on conflict(id) do update set
    display_name=case when public.profiles.display_name='' then excluded.display_name else public.profiles.display_name end,
    updated_at=now();
  return new;
end;
$$;

drop trigger if exists factoori_auth_user_profile on auth.users;
create trigger factoori_auth_user_profile
after insert on auth.users
for each row execute function private.handle_new_auth_user();

create or replace function private.create_business(p_name text)
returns uuid language plpgsql security definer
set search_path=''
as $$
declare v_user uuid:=auth.uid(); v_business_id uuid;
begin
  if v_user is null then raise exception using errcode='28000',message='Authentication required'; end if;
  if length(btrim(coalesce(p_name,''))) not between 2 and 160 then
    raise exception using errcode='22023',message='Business name must be between 2 and 160 characters';
  end if;
  insert into public.businesses(name,owner_user_id)
  values(btrim(p_name),v_user) returning id into v_business_id;
  insert into public.business_members(business_id,user_id,role_code,status,joined_at)
  values(v_business_id,v_user,'owner','active',now());
  insert into public.business_settings(business_id) values(v_business_id);
  return v_business_id;
end;
$$;

create or replace function public.create_business(p_name text)
returns uuid language sql security definer
set search_path=''
as $$ select private.create_business(p_name); $$;

create or replace function public.get_business_entitlements(p_business_id uuid)
returns jsonb language plpgsql stable security definer
set search_path=''
as $$
begin
  if not private.is_business_member(p_business_id) then
    raise exception using errcode='42501',message='Business access denied';
  end if;
  -- Subscription enforcement is deliberately not declared complete here.
  return jsonb_build_object('business_id',p_business_id,'plan_status','pending_entitlements');
end;
$$;

alter table public.profiles enable row level security;
alter table public.businesses enable row level security;
alter table public.permission_catalog enable row level security;
alter table public.business_members enable row level security;
alter table public.business_role_permissions enable row level security;
alter table public.business_member_permission_overrides enable row level security;
alter table public.business_settings enable row level security;

drop policy if exists profiles_select_self on public.profiles;
create policy profiles_select_self on public.profiles for select to authenticated using(id=auth.uid());
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update to authenticated using(id=auth.uid()) with check(id=auth.uid());

drop policy if exists businesses_select_member on public.businesses;
create policy businesses_select_member on public.businesses for select to authenticated using(private.is_business_member(id));

drop policy if exists permission_catalog_read on public.permission_catalog;
create policy permission_catalog_read on public.permission_catalog for select to authenticated using(true);

drop policy if exists business_members_read on public.business_members;
create policy business_members_read on public.business_members for select to authenticated
using(user_id=auth.uid() or private.has_business_permission(business_id,'members.read'));

drop policy if exists role_permissions_read on public.business_role_permissions;
create policy role_permissions_read on public.business_role_permissions for select to authenticated using(true);

drop policy if exists member_overrides_read on public.business_member_permission_overrides;
create policy member_overrides_read on public.business_member_permission_overrides for select to authenticated
using(private.has_business_permission(business_id,'members.manage'));

drop policy if exists business_settings_read on public.business_settings;
create policy business_settings_read on public.business_settings for select to authenticated
using(private.has_business_permission(business_id,'settings.read'));

revoke all on public.profiles,public.businesses,public.permission_catalog,public.business_members,
 public.business_role_permissions,public.business_member_permission_overrides,public.business_settings
from public,anon;
grant select on public.profiles,public.businesses,public.permission_catalog,public.business_members,
 public.business_role_permissions,public.business_member_permission_overrides,public.business_settings
to authenticated;
grant update(display_name,avatar_path) on public.profiles to authenticated;

revoke all on function private.is_business_member(uuid) from public,anon,authenticated;
revoke all on function private.has_business_permission(uuid,text) from public,anon,authenticated;
revoke all on function private.is_business_owner(uuid) from public,anon,authenticated;
revoke all on function private.create_business(text) from public,anon,authenticated;
revoke all on function private.handle_new_auth_user() from public,anon,authenticated;
revoke all on function private.touch_updated_at() from public,anon,authenticated;
revoke all on function public.create_business(text) from public,anon,authenticated;
revoke all on function public.get_business_entitlements(uuid) from public,anon,authenticated;
grant usage on schema private to authenticated;
grant execute on function private.is_business_member(uuid),private.has_business_permission(uuid,text),
 private.is_business_owner(uuid) to authenticated;
grant execute on function public.create_business(text),public.get_business_entitlements(uuid) to authenticated;

commit;
