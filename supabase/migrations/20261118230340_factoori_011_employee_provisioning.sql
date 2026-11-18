-- 011: Employee provisioning and warehouse role.
-- DEVELOPMENT DRAFT ONLY. Depends on drafts 001 and 007. Do not apply to production yet.
begin;

alter table public.business_members
  drop constraint if exists business_members_role_code_check;
alter table public.business_members
  add constraint business_members_role_code_check
  check (role_code in ('owner','admin','accountant','sales','viewer','warehouse'));

alter table public.business_role_permissions
  drop constraint if exists business_role_permissions_role_code_check;
alter table public.business_role_permissions
  add constraint business_role_permissions_role_code_check
  check (role_code in ('owner','admin','accountant','sales','viewer','warehouse'));

insert into public.business_role_permissions(role_code,permission_code,allowed)
select 'warehouse',p.code,
  p.code in ('business.read','catalog.read','inventory.read','inventory.adjust')
from public.permission_catalog p
on conflict(role_code,permission_code) do update set allowed=excluded.allowed;

create or replace function public.get_business_member_permissions(
  p_business_id uuid,p_member_user_id uuid default auth.uid()
)
returns table(permission_code text,allowed boolean,is_sensitive boolean)
language plpgsql stable security definer set search_path=''
as $$
declare v_role text; v_caller uuid:=auth.uid();
begin
  if v_caller is null then
    raise exception using errcode='28000',message='Authentication required';
  end if;
  if p_member_user_id is distinct from v_caller
     and not private.has_business_permission(p_business_id,'members.read') then
    raise exception using errcode='42501',message='Member permission read denied';
  end if;
  select m.role_code into v_role
  from public.business_members m
  where m.business_id=p_business_id and m.user_id=p_member_user_id and m.status='active';
  if v_role is null then
    raise exception using errcode='42501',message='Active business membership required';
  end if;
  return query
  select p.code,
    case when v_role='owner' then true else coalesce(o.allowed,rp.allowed,false) end,
    p.is_sensitive
  from public.permission_catalog p
  left join public.business_role_permissions rp
    on rp.role_code=v_role and rp.permission_code=p.code
  left join public.business_member_permission_overrides o
    on o.business_id=p_business_id and o.user_id=p_member_user_id
      and o.permission_code=p.code
  order by p.code;
end;
$$;

revoke all on function public.get_business_member_permissions(uuid,uuid) from public,anon;
grant execute on function public.get_business_member_permissions(uuid,uuid) to authenticated;


create or replace function public.provision_business_member(
  p_business_id uuid,p_user_id uuid,p_role_code text,p_invited_by uuid,
  p_permission_overrides jsonb default '[]'::jsonb
)
returns boolean language plpgsql security definer set search_path=''
as $$
declare v_item jsonb; v_code text; v_allowed boolean;
begin
  if coalesce(current_setting('request.jwt.claim.role',true),'')<>'service_role' then
    raise exception using errcode='42501',message='Service role required';
  end if;
  if p_role_code not in ('admin','accountant','sales','viewer','warehouse')
     or p_permission_overrides is null or jsonb_typeof(p_permission_overrides)<>'array' then
    raise exception using errcode='22023',message='Invalid member provisioning payload';
  end if;
  insert into public.business_members(business_id,user_id,role_code,status,invited_by,joined_at)
  values(p_business_id,p_user_id,p_role_code,'active',p_invited_by,now());
  for v_item in select value from jsonb_array_elements(p_permission_overrides)
  loop
    v_code:=v_item->>'code';
    v_allowed:=(v_item->>'allowed')::boolean;
    if v_code is null or v_allowed is null or not exists(
      select 1 from public.permission_catalog where code=v_code
    ) then
      raise exception using errcode='22023',message='Invalid permission override';
    end if;
    insert into public.business_member_permission_overrides(
      business_id,user_id,permission_code,allowed,reason,updated_by
    ) values(p_business_id,p_user_id,v_code,v_allowed,'Initial employee permissions',p_invited_by);
  end loop;
  perform private.write_business_audit(
    p_business_id,p_invited_by,'member.created','member',p_user_id::text,
    jsonb_build_object('role_code',p_role_code,'permission_override_count',jsonb_array_length(p_permission_overrides))
  );
  return true;
end;
$$;

revoke all on function public.provision_business_member(uuid,uuid,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.provision_business_member(uuid,uuid,text,uuid,jsonb) to service_role;

commit;
