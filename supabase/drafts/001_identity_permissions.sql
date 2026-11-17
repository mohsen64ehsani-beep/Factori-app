-- DRAFT ONLY. Do not apply to production.
begin;

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  phone text,
  avatar_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.businesses (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  slug text,
  owner_user_id uuid not null references public.profiles(id),
  status text not null default 'active' check (status in ('active','suspended','closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, owner_user_id)
);
create unique index businesses_slug_unique on public.businesses(lower(slug)) where slug is not null;

create table public.business_members (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  user_id uuid not null references public.profiles(id) on delete restrict,
  role_code text not null check (role_code in ('owner','admin','accountant','sales','viewer')),
  status text not null default 'active' check (status in ('invited','active','suspended','removed')),
  joined_at timestamptz,
  created_at timestamptz not null default now(),
  unique (business_id, user_id),
  unique (business_id, id),
  unique (business_id, user_id, id)
);
create index business_members_user_status_idx on public.business_members(user_id,status);

create table private.business_invitations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  invited_by uuid not null references public.profiles(id),
  invitee_email text,
  invitee_phone text,
  role_code text not null check (role_code in ('admin','accountant','sales','viewer')),
  token_hash text not null unique,
  status text not null default 'pending' check (status in ('pending','accepted','expired','revoked')),
  expires_at timestamptz not null,
  accepted_by uuid references public.profiles(id),
  accepted_at timestamptz,
  created_at timestamptz not null default now(),
  check (invitee_email is not null or invitee_phone is not null)
);

create table public.permission_catalog (
  code text primary key,
  module text not null,
  description text not null,
  is_sensitive boolean not null default false
);

create table public.business_role_permissions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  role_code text not null check (role_code in ('owner','admin','accountant','sales','viewer')),
  permission_code text not null references public.permission_catalog(code) on delete restrict,
  is_allowed boolean not null,
  created_at timestamptz not null default now(),
  unique (business_id,role_code,permission_code)
);

create table public.business_member_permission_overrides (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  member_id uuid not null,
  permission_code text not null references public.permission_catalog(code) on delete restrict,
  is_allowed boolean not null,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (business_id,member_id,permission_code),
  foreign key (business_id,member_id)
    references public.business_members(business_id,id) on delete cascade
);

create table public.business_audit_logs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  actor_user_id uuid references public.profiles(id),
  action_code text not null,
  entity_type text,
  entity_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index business_audit_logs_timeline_idx on public.business_audit_logs(business_id,created_at desc);

-- Security-definer helpers are private, fixed-search-path, schema-qualified and callable only by authenticated.
create or replace function private.is_business_member(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.business_members m
    join public.businesses b on b.id = m.business_id
    where m.business_id = p_business_id
      and m.user_id = (select auth.uid())
      and m.status = 'active'
      and b.status = 'active'
  );
$$;

create or replace function private.is_business_owner(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.business_members m
    join public.businesses b on b.id=m.business_id
    where m.business_id = p_business_id
      and m.user_id = (select auth.uid())
      and b.owner_user_id=(select auth.uid())
      and b.status='active'
      and m.role_code = 'owner'
      and m.status = 'active'
  );
$$;

create or replace function private.has_business_permission(p_business_id uuid,p_permission_code text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when (select private.is_business_owner(p_business_id)) then true
    else coalesce((
      select ov.is_allowed
      from public.business_members m
      join public.businesses b on b.id=m.business_id and b.status='active'
      left join public.business_member_permission_overrides ov
        on ov.business_id=m.business_id and ov.member_id=m.id and ov.permission_code=p_permission_code
      where m.business_id=p_business_id
        and m.user_id=(select auth.uid())
        and m.status='active'
      limit 1
    ),(
      select rp.is_allowed
      from public.business_members m
      join public.businesses b on b.id=m.business_id and b.status='active'
      join public.business_role_permissions rp
        on rp.business_id=m.business_id and rp.role_code=m.role_code
      where m.business_id=p_business_id
        and m.user_id=(select auth.uid())
        and m.status='active'
        and rp.permission_code=p_permission_code
      limit 1
    ),false)
  end;
$$;

revoke all on function private.is_business_member(uuid) from public,anon;
revoke all on function private.is_business_owner(uuid) from public,anon;
revoke all on function private.has_business_permission(uuid,text) from public,anon;
grant execute on function private.is_business_member(uuid) to authenticated;
grant execute on function private.is_business_owner(uuid) to authenticated;
grant execute on function private.has_business_permission(uuid,text) to authenticated;

-- Minimal permission catalog. Role matrices are seeded per business by the business-creation RPC.
insert into public.permission_catalog(code,module,description,is_sensitive) values
('contacts.read','contacts','Read contacts',false),
('contacts.write','contacts','Create and edit contacts',false),
('catalog.read','catalog','Read products and services',false),
('catalog.write','catalog','Manage products and services',false),
('catalog.cost.read','catalog','Read purchase costs',true),
('sales.read','sales','Read sales documents',false),
('sales.create','sales','Create sales documents',false),
('sales.edit_draft','sales','Edit draft sales documents',false),
('sales.post','sales','Post sales documents',false),
('sales.void','sales','Void sales documents',true),
('purchases.read','purchases','Read purchase documents',false),
('purchases.create','purchases','Create purchase documents',false),
('payments.read','finance','Read financial transactions',false),
('payments.create','finance','Create financial transactions',false),
('cheques.read','finance','Read cheque details',false),
('cheques.update_status','finance','Change cheque lifecycle status',false),
('inventory.read','inventory','Read inventory',false),
('inventory.adjust','inventory','Adjust inventory',true),
('inventory.transfer','inventory','Transfer stock between warehouses',false),
('expenses.read','finance','Read expenses',false),
('expenses.create','finance','Create expenses',false),
('reports.basic.read','reports','Read basic reports',false),
('reports.profit.read','reports','Read profit and margin reports',true),
('settings.manage','settings','Manage business settings',true),
('members.read','members','Read business members',false),
('members.manage','members','Invite and manage members',true),
('audit.read','audit','Read audit history',true),
('accounting.ledger.read','accounting','Read the general ledger',true),
('accounting.journal.post','accounting','Post balanced journal entries',true),
('settings.read','settings','Read basic business settings',false),
('invoice.settings.read','invoices','Read invoice presentation settings',false)
on conflict(code) do nothing;

commit;
