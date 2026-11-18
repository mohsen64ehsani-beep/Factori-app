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

## Automated isolated PostgreSQL tests

GitHub Actions workflow: `.github/workflows/factoori-database-tests.yml`.

The workflow starts a disposable PostgreSQL 17 service in the GitHub-hosted runner, creates only the minimal `auth.users` table, `auth.uid()` function and Supabase role names needed by these drafts, applies all ten draft migrations in dependency order, then runs all eleven SQL regression scripts. It does **not** connect to, create, or modify any Supabase project and does not require Supabase branching or a paid database.

This is a PostgreSQL integration test with a minimal Auth compatibility shim, **not a complete Supabase emulator**. Passing it will validate SQL parsing, migration ordering, object creation, grants/RLS metadata and the current regression assertions; it will not prove real Supabase Auth behavior, Edge Functions, JWT gateway behavior, Storage, production data migration, or every concurrent/runtime business scenario.

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

## Deliberately not included yet

- Invoice numbering sequences and complete fiscal close/reopen controls
- Journal reversal RPC, cheque lifecycle posting/assignment, and normalized invoice-to-ledger posting
- Full inventory adjustment/purchase/sale posting RPCs and materialized inventory balance projections
- Owner transfer, account deletion/retention and owner recovery
- Verified subscription upgrades, downgrades, grace periods and paid-plan entitlements
- Full multi-device sync runtime tests and normalized financial sync operations
- Legacy `db:v2` import/reconciliation and migration id mapping
- Private cheque-image storage and SMS retention policy

## Release gate

Do not move these drafts into `supabase/migrations/` or run them against the live project until:
1. schema dependencies and exact RPC signatures are reconciled;
2. the isolated PostgreSQL 17 workflow passes and its limitations are addressed with Supabase-specific verification;
3. cross-business RLS, permission matrix, concurrency, idempotency and data reconciliation tests pass;
4. rollback/restore plan and a complete migration package are prepared; and
5. the user explicitly approves production execution.
