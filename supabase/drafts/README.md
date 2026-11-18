# Shared database migration drafts

These files are **not production migrations**. They live under `supabase/drafts/` intentionally and have not been applied to the live Supabase project.

## Draft order

1. `001_identity_business_permissions.sql` — profiles, businesses, memberships, role defaults, permission helpers, business settings, and the initial Auth/RPC integration.
2. `002_core_documents.sql` — tenant-scoped contacts, warehouses, fiscal periods, document headers/items, and draft-only document creation.
3. `003_financial_ledger.sql` — accounts, receipts/payments, allocations, cheques, contact ledger and journal primitives.
4. `004_catalog_inventory.sql` — products/services, protected cost snapshots, stock movements, transfers and costing layers.
5. `004a_sync_infrastructure.sql` — sync device/cursor/operation tables and initial Free-tier quota enforcement.
6. `005_sync_compatibility.sql` — legacy compatibility sync bridge; currently limited to metadata and draft writes, with financial/stock mutations blocked pending normalized RPCs; **not production-ready**.
7. `006_journal_integrity.sql` — database guards for balanced, immutable posted journal entries.
8. `007_member_management.sql` — invitation acceptance, audited role changes and member suspension/removal.
9. `008_transactional_posting.sql` — atomic balanced-journal posting and stock-transfer posting with permission checks, idempotency and row locking.
10. `009_device_proof.sql` — P-256 challenge-response device verification, single-use nonces, device revocation and verified-device sync gate.
11. `010_account_transfers.sql` — financial account mapping and atomic paired transfer records with a balanced journal entry.
12. `011_employee_provisioning.sql` — service-role-only employee provisioning, warehouse role defaults and effective permission lookup.
13. `012_member_reactivation.sql` — audited reactivation/suspension controls with owner-only administrator status changes.
14. `013_account_bound_license_entitlements.sql` — authenticated account/business claim of verified perpetual licenses, idempotent same-owner claim, server-derived Premium status, and Premium-aware server quota bypass. Requires the existing license-key schema.
15. `014_legacy_normalized_mapping.sql` — private business-scoped legacy-to-normalized identity map; no source records are imported.
16. `015_legacy_normalization_preflight.sql` — read-only audit RPC for legacy collection quality and orphan references.

## Recent static-review fixes (2026-11-18)

- Corrected invalid PostgreSQL dollar-quote delimiters in migrations 001, 004, 004a and 007.
- Rebuilt the invitation creation/acceptance RPC section in 007 after detecting a truncated token-validation block; confirmed-email and SHA-256 token-hash checks are now explicit.
- Hardened 005 sync-pull pagination so unreadable collections cannot pin a device cursor.
- Enforced the per-invoice item limit on draft invoice updates as well as inserts.
- Restored draft invoices now consume the daily invoice quota again.
- Added static regression assertions for sync-pull cursor progress and invoice quota coverage.
- Wrapped migration 005 in a transaction so a failed apply cannot leave a partially created sync bridge.
- Extended migration 006 to reject DELETE as well as UPDATE on posted/reversed journal headers.
- Fixed the first PostgreSQL 17 integration failure: `stock_movements` now declares the composite unique key required by tenant-scoped inventory cost-layer foreign keys; migration 004 regression tests assert this key.
- Added employee provisioning and member reactivation migrations and wired their regression checks into CI so these security-sensitive changes are no longer skipped.

## Automated isolated PostgreSQL tests

GitHub Actions workflow: `.github/workflows/factoori-database-tests.yml`.

The workflow starts a disposable PostgreSQL 17 service in the GitHub-hosted runner, creates only the minimal `auth.users` table, `auth.uid()` function and Supabase role names needed by these drafts, applies all sixteen draft migrations in dependency order (013 is applied after a test-only license-schema fixture), then runs all eighteen SQL regression scripts. It does **not** connect to, create, or modify any Supabase project and does not require Supabase branching or a paid database.

This is a PostgreSQL integration test with a minimal Auth compatibility shim, **not a complete Supabase emulator**. Passing it validates SQL parsing, migration ordering, object creation, grants/RLS metadata and the current regression assertions; it does not prove real Supabase Auth behavior, Edge Functions, JWT gateway behavior, Storage, production data migration, or every concurrent/runtime business scenario.

The CI workflow creates an isolated fixture matching the existing `factori_license_keys` and `factori_license_activations` production schema, installs pgcrypto in the `extensions` schema, then applies draft 013. This fixture is test-only and is not a production migration.

The test scripts are:

- `supabase/tests/001_identity_business_permissions.sql`
- `supabase/tests/002_core_documents.sql`
- `supabase/tests/003_financial_ledger.sql`
- `supabase/tests/004_catalog_inventory.sql`
- `supabase/tests/004a_sync_infrastructure.sql`
- `supabase/tests/005_sync_compatibility.sql`
- `supabase/tests/006_journal_integrity.sql`
- `supabase/tests/007_member_management.sql`
- `supabase/tests/008_security_surface.sql`
- `supabase/tests/009_sensitive_payload_partition.sql`
- `supabase/tests/010_transactional_posting.sql`
- `supabase/tests/011_device_proof.sql`
- `supabase/tests/011_employee_provisioning.sql`
- `supabase/tests/012_account_transfers.sql`
- `supabase/tests/012_member_reactivation.sql`
- `supabase/tests/013_account_bound_license_entitlements.sql`
- `supabase/tests/014_legacy_normalized_mapping.sql`
- `supabase/tests/015_legacy_normalization_preflight.sql`

## Device proof deployment note

Migration 009, the `prove-sync-device` Edge Function source, and the Android/Web client key-challenge helpers are implemented on this development branch. The function is configured with gateway JWT verification and also validates the user's access token itself. Its cryptographic helper has Deno unit tests and the Edge Function is type-checked in CI. **The Edge Function has not been deployed to the live Supabase project**, and migration 009 has not been applied there.

## Deliberately not included yet

- Invoice numbering sequences and complete fiscal close/reopen controls
- Journal reversal RPC, cheque lifecycle posting/assignment, normalized invoice-to-ledger posting and purchase/expense/receipt RPCs
- Full inventory adjustment/purchase/sale posting RPCs and materialized inventory balance projections
- Owner transfer, account deletion/retention and owner recovery
- Verified subscription upgrades, downgrades, grace periods and paid-plan entitlements
- Full multi-device sync runtime tests and normalized financial sync operations
- Legacy `db:v2` normalized writes, import execution, and transactional financial/stock reconciliation (014 adds only the private identity map; 015 adds only a read-only preflight audit)
- Private cheque-image storage and SMS retention policy

## Release gate

Do not move these drafts into `supabase/migrations/` or run them against the live project until:
1. schema dependencies and exact RPC signatures are reconciled;
2. the isolated PostgreSQL 17 workflow passes and its limitations are addressed with Supabase-specific verification;
3. cross-business RLS, permission matrix, concurrency, idempotency and data reconciliation tests pass;
4. rollback/restore plan and a complete migration package are prepared; and
5. the user explicitly approves production execution.


## Legacy normalization preflight (015)

Migration 015 adds `public.preview_legacy_normalization(uuid)`, a read-only owner/admin preflight over the compatibility store. It reports collection counts, tombstones, malformed/mismatched legacy IDs, and orphan customer/product references in invoices. It does not expose payload values, read protected payloads, write normalized tables, post documents, or change inventory. Financial and stock collections remain explicitly deferred. The RPC requires `business.settings.manage`; anon/public execution is revoked. This is an audit gate, not an importer or proof of normalized synchronization.


## Legacy identity map (014)

Migration 014 creates the private `legacy_normalized_record_map` table. It binds a business-scoped legacy collection and ID to one normalized target UUID, stores a SHA-256 source fingerprint and import state, and intentionally stores no source payload. RLS is enabled and all direct client-role privileges are revoked. It is only an identity foundation; no records are imported by this migration.
