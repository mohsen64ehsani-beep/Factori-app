-- Regression assertions for device proof-of-possession and sync access gate.
begin;
do $$
declare v_fn text;
begin
 if to_regclass('public.sync_device_challenges') is null then raise exception 'Device challenge table missing'; end if;
 if not (select relrowsecurity from pg_class where oid='public.sync_device_challenges'::regclass) then
  raise exception 'Device challenge RLS must be enabled';
 end if;
 if has_table_privilege('authenticated','public.sync_device_challenges','SELECT')
   or has_table_privilege('authenticated','public.sync_device_challenges','INSERT') then
  raise exception 'Clients must not access device challenges directly';
 end if;
 if to_regprocedure('public.register_sync_device_secure(uuid,text,text,jsonb)') is null
   or to_regprocedure('public.create_sync_device_challenge(uuid,uuid)') is null
   or to_regprocedure('public.finalize_sync_device_proof(uuid,uuid,uuid,uuid,text)') is null
   or to_regprocedure('public.revoke_sync_device(uuid,uuid)') is null then
  raise exception 'Device proof RPC set is incomplete';
 end if;
 if has_function_privilege('authenticated','public.register_sync_device(uuid,text,text,jsonb)','EXECUTE')
   or has_function_privilege('authenticated','private.register_sync_device(uuid,text,text,jsonb)','EXECUTE')
   or has_function_privilege('authenticated','private.sync_push(uuid,uuid,jsonb)','EXECUTE')
   or has_function_privilege('authenticated','private.sync_pull(uuid,uuid,bigint,integer)','EXECUTE') then
  raise exception 'Legacy registration or private sync implementation must not be directly executable';
 end if;
 if has_function_privilege('authenticated','public.finalize_sync_device_proof(uuid,uuid,uuid,uuid,text)','EXECUTE')
   or not has_function_privilege('service_role','public.finalize_sync_device_proof(uuid,uuid,uuid,uuid,text)','EXECUTE') then
  raise exception 'Only service_role may finalize proof after Edge Function verification';
 end if;
 if not has_function_privilege('authenticated','public.register_sync_device_secure(uuid,text,text,jsonb)','EXECUTE')
   or not has_function_privilege('authenticated','public.create_sync_device_challenge(uuid,uuid)','EXECUTE')
   or not has_function_privilege('authenticated','public.revoke_sync_device(uuid,uuid)','EXECUTE') then
  raise exception 'Authenticated device lifecycle RPC grants are missing';
 end if;
 v_fn:=pg_get_functiondef('public.sync_push(uuid,uuid,jsonb)'::regprocedure);
 if position('verified_at is not null' in lower(v_fn))=0 or position('proof_version=1' in v_fn)=0
   or position('private.sync_push' in v_fn)=0 then
  raise exception 'sync_push does not require verified device proof';
 end if;
 v_fn:=pg_get_functiondef('public.sync_pull(uuid,uuid,bigint,integer)'::regprocedure);
 if position('verified_at is not null' in lower(v_fn))=0 or position('proof_version=1' in v_fn)=0
   or position('private.sync_pull' in v_fn)=0 then
  raise exception 'sync_pull does not require verified device proof';
 end if;
 v_fn:=pg_get_functiondef('public.create_sync_device_challenge(uuid,uuid)'::regprocedure);
 if position('for update of d' in lower(v_fn))=0 or position('v_recent_count>=10' in v_fn)=0
   or position('interval ''10 minutes''' in v_fn)=0 then
  raise exception 'Device challenge rate limit or serialization lock is missing';
 end if;
 v_fn:=pg_get_functiondef('public.finalize_sync_device_proof(uuid,uuid,uuid,uuid,text)'::regprocedure);
 if position('consumed_at is null' in v_fn)=0 or position('expires_at<=now()' in v_fn)=0
   or position('for update' in lower(v_fn))=0 then
  raise exception 'Challenge expiry, single-use or row-lock checks are missing';
 end if;
end $$;
rollback;
