-- Security and integrity checks for the private legacy identity map.
begin;
do $$
declare v_rls boolean;
begin
 if to_regclass('private.legacy_normalized_record_map') is null then
  raise exception 'Legacy normalized identity map is missing';
 end if;
 select c.relrowsecurity into v_rls from pg_class c where c.oid='private.legacy_normalized_record_map'::regclass;
 if not coalesce(v_rls,false) then raise exception 'Legacy identity map must have RLS enabled'; end if;
 if has_table_privilege('anon','private.legacy_normalized_record_map','SELECT')
  or has_table_privilege('authenticated','private.legacy_normalized_record_map','SELECT')
  or has_table_privilege('anon','private.legacy_normalized_record_map','INSERT')
  or has_table_privilege('authenticated','private.legacy_normalized_record_map','INSERT')
  or has_table_privilege('authenticated','private.legacy_normalized_record_map','UPDATE')
  or has_table_privilege('authenticated','private.legacy_normalized_record_map','DELETE') then
  raise exception 'Client roles must not access private identity mappings';
 end if;
 if not exists(select 1 from pg_constraint where conrelid='private.legacy_normalized_record_map'::regclass
  and contype='u' and pg_get_constraintdef(oid) like '%business_id, legacy_collection, legacy_id%') then
  raise exception 'Legacy source identity uniqueness is missing';
 end if;
 if not exists(select 1 from pg_constraint where conrelid='private.legacy_normalized_record_map'::regclass
  and contype='u' and pg_get_constraintdef(oid) like '%business_id, target_table, normalized_id%') then
  raise exception 'Normalized target identity uniqueness is missing';
 end if;
 if not exists(select 1 from pg_constraint where conrelid='private.legacy_normalized_record_map'::regclass
  and contype='c' and pg_get_constraintdef(oid) like '%source_fingerprint%'
  and pg_get_constraintdef(oid) like '%64%') then
  raise exception 'SHA-256 source fingerprint constraint is missing';
 end if;
end $$;
rollback;
