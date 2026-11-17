-- Disposable static checks for 005 compatibility sync hardening.
-- Requires migrations 001-005 and predecessor sync tables/functions in isolated staging.
begin;
do $$
declare v_def text;
begin
 select pg_get_functiondef('private.sync_push(uuid,uuid,jsonb)'::regprocedure) into v_def;
 if position('request_fingerprint' in v_def)=0
  or position('sync_operation_id_reused_with_different_payload' in v_def)=0 then
  raise exception 'Sync operation payload fingerprint validation is missing';
 end if;
 if position('pg_advisory_xact_lock' in v_def)=0 then
  raise exception 'Sync idempotency advisory lock is missing';
 end if;
 if position('262144' in v_def)=0 then
  raise exception 'Sync payload byte limit is missing';
 end if;
 if position('document_sync_accepts_drafts_only' in v_def)=0 then
  raise exception 'Draft-only document status guard is missing';
 end if;
 if position('v_error' in v_def)>0 and position('''message'',v_error' in v_def)>0 then
  raise exception 'Raw database error is exposed to sync clients';
 end if;
 if position('customers.total_limit' in v_def)=0
  or position('products.total_limit' in v_def)=0
  or position('services.total_limit' in v_def)=0 then
  raise exception 'Catalog quotas are not enforced in sync';
 end if;
 if position('operation_rejected' in v_def)=0 then
  raise exception 'Sanitized rejection message is missing';
 end if;

 select pg_get_functiondef('private.can_sync_collection(uuid,text,text)'::regprocedure) into v_def;
 if position('when ''pay'' then null' in v_def)=0
  or position('when ''purchases'' then null' in v_def)=0
  or position('when ''stockMoves'' then null' in v_def)
    =0 then
  raise exception 'Financial and stock mutation collections must remain blocked in generic sync';
 end if;
end $$;
rollback;
