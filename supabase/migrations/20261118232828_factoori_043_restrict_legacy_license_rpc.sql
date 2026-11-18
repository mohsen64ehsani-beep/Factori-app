begin;
revoke all on function public.activate_license(text,text) from public,anon,authenticated;
grant execute on function public.activate_license(text,text) to service_role;
commit;