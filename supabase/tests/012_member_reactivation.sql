-- Disposable checks for 012. Run after drafts 001 and 007 in isolated staging.
begin;
do $$
declare v_definition text;
begin
 v_definition:=pg_get_functiondef('public.set_business_member_status(uuid,uuid,text)'::regprocedure);
 if position('active' in v_definition)=0 or position('suspended' in v_definition)=0 then
  raise exception 'Member status RPC must support reactivation and suspension';
 end if;
 if position('v_target.status=''removed''' in v_definition)=0 then
  raise exception 'Removed members must not be silently reactivated';
 end if;
 if position('Only the owner can change an administrator status' in v_definition)=0 then
  raise exception 'Administrator status protection missing';
 end if;
 if not has_function_privilege('authenticated','public.set_business_member_status(uuid,uuid,text)','EXECUTE') then
  raise exception 'Authenticated member status RPC missing';
 end if;
 if has_function_privilege('anon','public.set_business_member_status(uuid,uuid,text)','EXECUTE') then
  raise exception 'Anonymous member status RPC must be disabled';
 end if;
end $$;
rollback;
