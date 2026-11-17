-- Disposable checks for 007. Run after migration 001 in isolated staging.
begin;
do $$
declare t text; r record;
begin
 foreach t in array array['business_invitations','business_audit_logs'] loop
  if to_regclass('public.'||t) is null then raise exception 'Missing public.%',t; end if;
  select c.relrowsecurity into r from pg_class c where c.oid=to_regclass('public.'||t);
  if not r.relrowsecurity then raise exception 'RLS disabled on public.%',t; end if;
  if has_table_privilege('anon','public.'||t,'SELECT') then raise exception 'anon can read public.%',t; end if;
  if has_table_privilege('authenticated','public.'||t,'INSERT') then raise exception 'authenticated can directly insert public.%',t; end if;
  if has_table_privilege('authenticated','public.'||t,'UPDATE') then raise exception 'authenticated can directly update public.%',t; end if;
  if has_table_privilege('authenticated','public.'||t,'DELETE') then raise exception 'authenticated can directly delete public.%',t; end if;
 end loop;
 if position('email_confirmed_at is not null' in pg_get_functiondef('public.accept_business_invitation(text)'::regprocedure))=0 then
  raise exception 'Invitation acceptance must require a confirmed email';
 end if;
 if position('Only the owner can change an administrator role' in pg_get_functiondef('public.update_business_member_role(uuid,uuid,text)'::regprocedure))=0 then
  raise exception 'Administrator role change restriction is missing';
 end if;
 if position('Only the owner can suspend or remove an administrator' in pg_get_functiondef('public.set_business_member_status(uuid,uuid,text)'::regprocedure))=0 then
  raise exception 'Administrator suspension restriction is missing';
 end if;
 if position('Only the owner can assign administrator role' in pg_get_functiondef('public.update_business_member_role(uuid,uuid,text)'::regprocedure))=0 then
  raise exception 'Administrator role assignment restriction is missing';
 end if;
 if not has_function_privilege('authenticated','public.accept_business_invitation(text)','EXECUTE') then
  raise exception 'Authenticated invitation acceptance RPC missing';
 end if;
 if has_function_privilege('anon','public.accept_business_invitation(text)','EXECUTE') then
  raise exception 'Anonymous invitation acceptance must be disabled';
 end if;
 if has_function_privilege('authenticated','private.write_business_audit(uuid,uuid,text,text,text,jsonb)','EXECUTE') then
  raise exception 'Audit helper must not be directly callable by clients';
 end if;
end $$;
rollback;
