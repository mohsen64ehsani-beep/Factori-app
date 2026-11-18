-- 043: Legacy license activation RPC is callable only by the trusted Edge Function service role.
begin;
do $$
begin
 if has_function_privilege('anon','public.activate_license(text,text)','EXECUTE') then
  raise exception 'Anonymous callers must not execute the legacy license activation RPC';
 end if;
 if has_function_privilege('authenticated','public.activate_license(text,text)','EXECUTE') then
  raise exception 'Authenticated clients must use the signed Edge Function for license activation';
 end if;
 if not has_function_privilege('service_role','public.activate_license(text,text)','EXECUTE') then
  raise exception 'Service role must retain license activation RPC access';
 end if;
end $$;
rollback;
