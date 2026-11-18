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

commit;
