-- 007: Business invitations, audited member administration and immutable audit trail.
-- DEVELOPMENT DRAFT ONLY. Depends on 001_identity_business_permissions.sql.
begin;

create table if not exists public.business_invitations (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 email_normalized text not null check(email_normalized=lower(btrim(email_normalized)) and email_normalized like '%@%'),
 role_code text not null check(role_code in ('admin','accountant','sales','viewer')),
 token_hash text not null check(length(token_hash)=64 and token_hash ~ '^[a-f0-9]{64}$'),
 status text not null default 'pending' check(status in ('pending','accepted','revoked','expired')),
 invited_by uuid not null references auth.users(id) on delete restrict,
 accepted_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now(),
 expires_at timestamptz not null,
 accepted_at timestamptz,
 revoked_at timestamptz,
 unique(business_id,id),
 unique(token_hash),
 check(expires_at>created_at)
);
create unique index if not exists business_invitations_one_pending_per_email
 on public.business_invitations(business_id,email_normalized)
 where status='pending';
create index if not exists business_invitations_business_status_idx
 on public.business_invitations(business_id,status,created_at desc);

create table if not exists public.business_audit_logs (
 id bigint generated always as identity primary key,
 business_id uuid not null references public.businesses(id) on delete cascade,
 actor_user_id uuid references auth.users(id) on delete set null,
 action_code text not null check(action_code ~ '^[a-z][a-z0-9_.-]{1,100}$'),
 entity_type text not null,
 entity_id text,
 metadata jsonb not null default '{}'::jsonb check(jsonb_typeof(metadata)='object'),
 created_at timestamptz not null default now()
);
create index if not exists business_audit_logs_timeline_idx
 on public.business_audit_logs(business_id,created_at desc,id);
create index if not exists business_audit_logs_actor_idx
 on public.business_audit_logs(business_id,actor_user_id,created_at desc);

alter table public.business_invitations enable row level security;
alter table public.business_audit_logs enable row level security;
drop policy if exists business_invitations_read on public.business_invitations;
create policy business_invitations_read on public.business_invitations for select to authenticated
 using(private.has_business_permission(business_id,'members.manage'));
drop policy if exists business_audit_logs_read on public.business_audit_logs;
create policy business_audit_logs_read on public.business_audit_logs for select to authenticated
 using(private.has_business_permission(business_id,'audit.read'));
revoke all on public.business_invitations,public.business_audit_logs from public,anon;
grant select on public.business_invitations,public.business_audit_logs to authenticated;

update public.permission_catalog set is_sensitive=true
where code in (
 'members.manage','business.settings.manage','settings.manage','audit.read',
 'sales.post','sales.void','purchases.create','purchases.post',
 'payments.create','payments.refund','cheques.update_status',
 'inventory.adjust','inventory.transfer','expenses.create','accounting.journal.post'
);

create or replace function private.write_business_audit(
 p_business_id uuid,p_actor uuid,p_action text,p_entity_type text,p_entity_id text,p_metadata jsonb default '{}'::jsonb
)
returns void language plpgsql security definer set search_path=''
as $$
begin
 if p_metadata is null or jsonb_typeof(p_metadata)<>'object' then
  raise exception using errcode='22023',message='Audit metadata must be an object';
 end if;
 insert into public.business_audit_logs(business_id,actor_user_id,action_code,entity_type,entity_id,metadata)
 values(p_business_id,p_actor,p_action,p_entity_type,p_entity_id,p_metadata);
end;
$$;

create or replace function public.create_business_invitation(
 p_business_id uuid,p_email text,p_role_code text,p_token_hash text,p_expires_at timestamptz
)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_user uuid:=auth.uid(); v_id uuid; v_email text;
begin
 if v_user is null or not private.has_business_permission(p_business_id,'members.manage') then
  raise exception using errcode='42501',message='Member management is not permitted';
 end if;
 v_email:=lower(btrim(coalesce(p_email,'')));
 if v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
  raise exception using errcode='22023',message='Invalid invitation email';
 end if;
 if p_role_code is null or p_role_code not in ('admin','accountant','sales','viewer') then
  raise exception using errcode='22023',message='Invalid invitation role';
 end if;
 if p_role_code='admin' and not private.is_business_owner(p_business_id) then
  raise exception using errcode='42501',message='Only the owner can invite an administrator';
 end if;
 if p_token_hash is null or length(p_token_hash)<>64 or p_token_hash !~ '^[a-f0-9]{64}$' then
  raise exception using errcode='22023',message='Invalid invitation token hash';
 end if;
 if p_expires_at is null or p_expires_at<=now() or p_expires_at>now()+interval '30 days' then
  raise exception using errcode='22023',message='Invitation expiry must be within 30 days';
 end if;
 update public.business_invitations set status='expired'
 where business_id=p_business_id and email_normalized=v_email
   and status='pending' and expires_at<=now();
 insert into public.business_invitations(business_id,email_normalized,role_code,token_hash,invited_by,expires_at)
 values(p_business_id,v_email,p_role_code,p_token_hash,v_user,p_expires_at)
 returning id into v_id;
 perform private.write_business_audit(p_business_id,v_user,'member.invitation.created','invitation',v_id::text,
  jsonb_build_object('email',v_email,'role_code',p_role_code,'expires_at',p_expires_at));
 return v_id;
end;
$$;

create or replace function public.accept_business_invitation(p_token_hash text)
returns uuid language plpgsql security definer set search_path=''
as $$
declare
 v_user uuid:=auth.uid(); v_email text; v_inv public.business_invitations%rowtype; v_rows integer;
begin
 if v_user is null then raise exception using errcode='28000',message='Authentication required'; end if;
 if p_token_hash is null or length(p_token_hash)<>64 or p_token_hash !~ '^[a-f0-9]{64} into v_email from auth.users where id=v_user and email_confirmed_at is not null;
 if v_email is null then raise exception using errcode='42501',message='Authenticated email is unavailable'; end if;
 select * into v_inv from public.business_invitations
 where token_hash=p_token_hash and status='pending'
 for update;
 if not found or v_inv.expires_at<=now() then
  raise exception using errcode='22023',message='Invitation is invalid or expired';
 end if;
 if v_inv.email_normalized<>v_email then
  raise exception using errcode='42501',message='Invitation email does not match the signed-in account';
 end if;
 insert into public.business_members(business_id,user_id,role_code,status,invited_by,joined_at)
 values(v_inv.business_id,v_user,v_inv.role_code,'active',v_inv.invited_by,now())
 on conflict(business_id,user_id) do update
 set role_code=excluded.role_code,status='active',invited_by=excluded.invited_by,
     joined_at=now(),updated_at=now()
 where public.business_members.status in ('invited','removed','suspended');
 get diagnostics v_rows=row_count;
 if v_rows=0 then raise exception using errcode='23505',message='User is already an active business member'; end if;
 update public.business_invitations set status='accepted',accepted_by=v_user,accepted_at=now()
 where id=v_inv.id;
 perform private.write_business_audit(v_inv.business_id,v_user,'member.invitation.accepted','invitation',v_inv.id::text,
  jsonb_build_object('role_code',v_inv.role_code));
 return v_inv.business_id;
end;
$$;

create or replace function public.revoke_business_invitation(p_invitation_id uuid)
returns boolean language plpgsql security definer set search_path=''
as $$
declare v_user uuid:=auth.uid(); v_inv public.business_invitations%rowtype;
begin
 select * into v_inv from public.business_invitations where id=p_invitation_id for update;
 if not found or v_user is null or not private.has_business_permission(v_inv.business_id,'members.manage') then
  raise exception using errcode='42501',message='Invitation access denied';
 end if;
 if v_inv.status<>'pending' then return false; end if;
 update public.business_invitations set status='revoked',revoked_at=now() where id=v_inv.id;
 perform private.write_business_audit(v_inv.business_id,v_user,'member.invitation.revoked','invitation',v_inv.id::text,'{}'::jsonb);
 return true;
end;
$$;

create or replace function public.update_business_member_role(p_business_id uuid,p_member_user_id uuid,p_role_code text)
returns boolean language plpgsql security definer set search_path=''
as $$
declare v_user uuid:=auth.uid(); v_target public.business_members%rowtype;
begin
 if v_user is null or not private.has_business_permission(p_business_id,'members.manage') then
  raise exception using errcode='42501',message='Member management is not permitted';
 end if;
 if p_role_code is null or p_role_code not in ('admin','accountant','sales','viewer') then
  raise exception using errcode='22023',message='Invalid member role';
 end if;
 if p_role_code='admin' and not private.is_business_owner(p_business_id) then
  raise exception using errcode='42501',message='Only the owner can assign administrator role';
 end if;
 select * into v_target from public.business_members
 where business_id=p_business_id and user_id=p_member_user_id for update;
 if not found or v_target.status<>'active' or v_target.role_code='owner' or p_member_user_id=v_user then
  raise exception using errcode='42501',message='This member role cannot be changed';
 end if;
 if v_target.role_code='admin' and not private.is_business_owner(p_business_id) then
  raise exception using errcode='42501',message='Only the owner can change an administrator role';
 end if;
 update public.business_members set role_code=p_role_code,updated_at=now()
 where business_id=p_business_id and user_id=p_member_user_id;
 perform private.write_business_audit(p_business_id,v_user,'member.role.updated','member',p_member_user_id::text,
  jsonb_build_object('old_role',v_target.role_code,'new_role',p_role_code));
 return true;
end;
$$;

create or replace function public.set_business_member_status(p_business_id uuid,p_member_user_id uuid,p_status text)
returns boolean language plpgsql security definer set search_path=''
as $$
declare v_user uuid:=auth.uid(); v_target public.business_members%rowtype;
begin
 if v_user is null or not private.has_business_permission(p_business_id,'members.manage') then
  raise exception using errcode='42501',message='Member management is not permitted';
 end if;
 if p_status is null or p_status not in ('suspended','removed') then
  raise exception using errcode='22023',message='Invalid member status';
 end if;
 select * into v_target from public.business_members
 where business_id=p_business_id and user_id=p_member_user_id for update;
 if not found or v_target.status<>'active' or v_target.role_code='owner' or p_member_user_id=v_user then
  raise exception using errcode='42501',message='This member cannot be suspended or removed';
 end if;
 if v_target.role_code='admin' and not private.is_business_owner(p_business_id) then
  raise exception using errcode='42501',message='Only the owner can suspend or remove an administrator';
 end if;
 update public.business_members set status=p_status,updated_at=now()
 where business_id=p_business_id and user_id=p_member_user_id;
 perform private.write_business_audit(p_business_id,v_user,'member.status.updated','member',p_member_user_id::text,
  jsonb_build_object('old_status',v_target.status,'new_status',p_status));
 return true;
end;
$$;

create or replace function public.set_business_member_permission_override(
 p_business_id uuid,p_member_user_id uuid,p_permission_code text,p_allowed boolean,p_reason text default null
)
returns boolean language plpgsql security definer set search_path=''
  as $$
declare
 v_user uuid:=auth.uid(); v_target public.business_members%rowtype; v_sensitive boolean;
begin
 if v_user is null or not private.has_business_permission(p_business_id,'members.manage') then
  raise exception using errcode='42501',message='Member permission management is not permitted';
 end if;
 if p_allowed is null or p_permission_code is null then
  raise exception using errcode='22023',message='Permission and decision are required';
 end if;
 select is_sensitive into v_sensitive from public.permission_catalog where code=p_permission_code;
 if not found then raise exception using errcode='22023',message='Unknown permission code'; end if;
 select * into v_target from public.business_members
 where business_id=p_business_id and user_id=p_member_user_id for update;
 if not found or v_target.status<>'active' or v_target.role_code='owner' or p_member_user_id=v_user then
  raise exception using errcode='42501',message='This member permission cannot be changed';
 end if;
 if v_target.role_code='admin' and not private.is_business_owner(p_business_id) then
  raise exception using errcode='42501',message='Only the owner can change administrator permissions';
 end if;
 if v_sensitive and p_allowed and not private.is_business_owner(p_business_id) then
  raise exception using errcode='42501',message='Only the owner can grant sensitive permissions';
 end if;
 insert into public.business_member_permission_overrides(
  business_id,user_id,permission_code,allowed,reason,updated_by,updated_at
 ) values(
  p_business_id,p_member_user_id,p_permission_code,p_allowed,
  nullif(left(btrim(coalesce(p_reason,'')),500),''),v_user,now()
 )
 on conflict(business_id,user_id,permission_code) do update
 set allowed=excluded.allowed,reason=excluded.reason,updated_by=excluded.updated_by,updated_at=now();
 perform private.write_business_audit(p_business_id,v_user,'member.permission.updated','member',p_member_user_id::text,
  jsonb_build_object('permission_code',p_permission_code,'allowed',p_allowed));
 return true;
end;
$$;

create or replace function public.clear_business_member_permission_override(
 p_business_id uuid,p_member_user_id uuid,p_permission_code text
)
returns boolean language plpgsql security definer set search_path=''
  as $$
declare v_user uuid:=auth.uid(); v_target public.business_members%rowtype; v_deleted integer;
begin
 if v_user is null or not private.has_business_permission(p_business_id,'members.manage') then
  raise exception using errcode='42501',message='Member permission management is not permitted';
 end if;
 select * into v_target from public.business_members
 where business_id=p_business_id and user_id=p_member_user_id for update;
 if not found or v_target.status<>'active' or v_target.role_code='owner' or p_member_user_id=v_user then
  raise exception using errcode='42501',message='This member permission cannot be changed';
 end if;
 if v_target.role_code='admin' and not private.is_business_owner(p_business_id) then
  raise exception using errcode='42501',message='Only the owner can change administrator permissions';
 end if;
 delete from public.business_member_permission_overrides
 where business_id=p_business_id and user_id=p_member_user_id and permission_code=p_permission_code;
 get diagnostics v_deleted=row_count;
 if v_deleted>0 then
  perform private.write_business_audit(p_business_id,v_user,'member.permission.cleared','member',p_member_user_id::text,
   jsonb_build_object('permission_code',p_permission_code));
 end if;
 return v_deleted>0;
end;
$$;

revoke all on function private.write_business_audit(uuid,uuid,text,text,text,jsonb) from public,anon,authenticated;
revoke all on function public.create_business_invitation(uuid,text,text,text,timestamptz) from public,anon,authenticated;
revoke all on function public.accept_business_invitation(text) from public,anon,authenticated;
revoke all on function public.revoke_business_invitation(uuid) from public,anon,authenticated;
revoke all on function public.update_business_member_role(uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.set_business_member_status(uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.set_business_member_permission_override(uuid,uuid,text,boolean,text) from public,anon,authenticated;
revoke all on function public.clear_business_member_permission_override(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.create_business_invitation(uuid,text,text,text,timestamptz) to authenticated;
grant execute on function public.accept_business_invitation(text) to authenticated;
grant execute on function public.revoke_business_invitation(uuid) to authenticated;
grant execute on function public.update_business_member_role(uuid,uuid,text) to authenticated;
grant execute on function public.set_business_member_status(uuid,uuid,text) to authenticated;
grant execute on function public.set_business_member_permission_override(uuid,uuid,text,boolean,text) to authenticated;
grant execute on function public.clear_business_member_permission_override(uuid,uuid,text) to authenticated;

commit;
