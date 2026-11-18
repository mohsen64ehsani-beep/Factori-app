-- 015: Private identity map for legacy db:v2 records projected into normalized tables.
-- DEVELOPMENT DRAFT ONLY. No source rows are imported by this migration.
begin;

create table if not exists private.legacy_normalized_record_map (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  legacy_collection text not null check (legacy_collection in (
    'cust','prod','categories','warehouses','services','inv','serviceInv'
  )),
  legacy_id text not null check (length(btrim(legacy_id)) between 1 and 200),
  target_table text not null check (target_table in (
    'contacts','products','product_categories','warehouses','services','documents'
  )),
  normalized_id uuid not null,
  source_fingerprint text not null check (source_fingerprint ~ '^[0-9a-f]{64}$'),
  import_status text not null default 'mapped' check (import_status in (
    'mapped','needs_review','conflict','orphaned','retired'
  )),
  first_imported_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  last_imported_at timestamptz not null default now(),
  import_generation uuid not null,
  note_code text check (note_code is null or note_code in (
    'duplicate_legacy_id','missing_reference','invalid_payload','target_conflict',
    'source_changed','unsupported_shape','permission_denied'
  )),
  created_by uuid references auth.users(id) on delete set null,
  unique (business_id, legacy_collection, legacy_id),
  unique (business_id, target_table, normalized_id),
  unique (business_id, id)
);

create index if not exists legacy_normalized_map_status_idx
  on private.legacy_normalized_record_map (business_id, import_status, legacy_collection);
create index if not exists legacy_normalized_map_generation_idx
  on private.legacy_normalized_record_map (business_id, import_generation, legacy_collection);

alter table private.legacy_normalized_record_map enable row level security;
revoke all on private.legacy_normalized_record_map from public, anon, authenticated;

comment on table private.legacy_normalized_record_map is
  'Private tenant-scoped identity map for the staged db:v2 to normalized data bridge. Contains no source payload.';
comment on column private.legacy_normalized_record_map.source_fingerprint is
  'SHA-256 hex fingerprint of the canonical source row; detects unchanged rows and import conflicts.';
comment on column private.legacy_normalized_record_map.import_generation is
  'UUID identifying one preflight/import pass; supports safe reconciliation without deleting source records.';

commit;
