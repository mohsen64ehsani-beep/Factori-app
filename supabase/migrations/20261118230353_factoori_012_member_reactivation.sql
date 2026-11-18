-- 012: Allow owners/managers to reactivate suspended employees.
-- DEVELOPMENT DRAFT ONLY. Depends on 001 and 007.
begin;

create or replace function public.set_business_member_status(
 p_business_id uuid,p_member_user_id uuid,p_status text
)
returns boolean language plpgsql security definer set search_path=''
as $$
declare v_user uuid:=auth.uid(); v_target public.business_members%rowtype;
begin
 if v_user is null or not private.has_business_permission(p_business_id,'members.manage') then
  raise exception using errcode='42501',message='Member management is not permitted';
 end if;
 if p_status is null or p_status not in ('active','suspended','removed') then
  raise exception using errcode='22023',message='Invalid member status';
 end if;
 select * into v_target from public.business_members
 where business_id=p_business_id and user_id=p_member_user_id for update;
 if not found or v_target.status='removed' or v_target.role_code='owner' or p_member_user_id=v_user then
  raise exception using errcode='42501',message='This member cannot be reactivated, suspended or removed';
 end if;
 if v_target.role_code='admin' and not private.is_business_owner(p_business_id) then
  raise exception using errcode='42501',message='Only the owner can change an administrator status';
 end if;
 if v_target.status=p_status then return false; end if;
 update public.business_members set status=p_status,updated_at=now()
 where business_id=p_business_id and user_id=p_member_user_id;
 perform private.write_business_audit(p_business_id,v_user,'member.status.updated','member',p_member_user_id::text,
  jsonb_build_object('old_status',v_target.status,'new_status',p_status));
 return true;
end;
$$;

revoke all on function public.set_business_member_status(uuid,uuid,text) from public,anon;
grant execute on function public.set_business_member_status(uuid,uuid,text) to authenticated;

commit;
