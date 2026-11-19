begin;
do $$
declare v_oid regprocedure;v_def text;
begin
 if not has_function_privilege('authenticated','public.web_list_business_members(uuid)','execute')
    or has_function_privilege('anon','public.web_list_business_members(uuid)','execute') then
  raise exception 'Business member listing grants are incorrect';
 end if;
 select p.oid::regprocedure into v_oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='web_list_business_members';
 select pg_get_functiondef(v_oid::oid) into v_def;
 if v_def not ilike '%members.manage%' or v_def not ilike '%auth.users%' then
  raise exception 'Business member listing is missing permission gate or member email lookup';
 end if;
end;
$$;
rollback;
