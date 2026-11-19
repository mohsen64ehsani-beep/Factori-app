create or replace function public.web_list_business_members(p_business_id uuid)
returns table(user_id uuid,email text,role_code text,status text,joined_at timestamptz,created_at timestamptz)
language plpgsql
security definer
set search_path=''
as $function$
begin
 if auth.uid() is null or not private.has_business_permission(p_business_id,'members.manage') then
  raise exception using errcode='42501',message='Member management is not permitted';
 end if;
 return query
 select bm.user_id,u.email::text,bm.role_code,bm.status,bm.joined_at,bm.created_at
 from public.business_members bm
 join auth.users u on u.id=bm.user_id
 where bm.business_id=p_business_id
 order by case bm.role_code when 'owner' then 0 when 'admin' then 1 else 2 end,bm.created_at;
end;$function$;
revoke all on function public.web_list_business_members(uuid) from public,anon;
grant execute on function public.web_list_business_members(uuid) to authenticated;
