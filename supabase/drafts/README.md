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

## Recent static-review fixes (2026-11-18)

- Corrected invalid PostgreSQL dollar-quote delimiters in migrations 001, 004, 004a and 007.
- Rebuilt the invitation creation/acceptance RPC section in 007 after detecting a truncated token-validation block; confirmed-email and SHA-256 token-hash checks are now explicit.
- Hardened 005 sync-pull pagination so unreadable collections cannot pin a device cursor.
- Enforced the per-invoice item limit on draft invoice updates as well as inserts.
- Restored draft invoices now consume the daily invoice quota again.
- Added static regression assertions for sync-pull cursor progress and invoice quota coverage.
- These are source-level fixes only; no production migration has been applied. Runtime SQL tests still require a disposable staging database.

## Test scripts

- `supabase/tests/001_identity_business_permissions.sql`
- `supabase/tests/002_core_documents.sql`
- `supabase/tests/003_financial_ledger.sql`
- `supabase/tests/004_catalog_inventory.sql`
- `supabase/tests/004a_sync_infrastructure.sql`
- `supabase/tests/005_sync_compatibility.sql`
- `supabase/tests/006_journal_integrity.sql`
- `supabase/tests/007_member_management.sql`

The test scripts are designed for an isolated disposable Supabase/Postgres project after applying the corresponding draft migrations. They have not been run against production.

## Deliberately not included yet

- Invoice numbering sequences and complete fiscal close/reopen controls
- Posting/reversal RPCs and cheque assignment lifecycle (journal integrity guards are drafted, but the posting engine is not)
- Server-side stock mutation RPCs and inventory balance projections
- Owner transfer, account deletion/retention and owner recovery
- Verified subscription upgrades, downgrades, grace periods and paid-plan entitlements
- Device proof-of-possession, full multi-device sync tests and normalized financial sync operations
- Legacy `db:v2` import/reconciliation and migration id mapping
- Private cheque-image storage and SMS retention policy

## Release gate

Do not move these drafts into `supabase/migrations/` or run them against the live project until:
1. schema dependencies and exact RPC signatures are reconciled;
2. SQL syntax and tests pass in a disposable staging project;
3. cross-business RLS, permission matrix, concurrency, idempotency and data reconciliation tests pass;
4. rollback/restore plan and a complete migration package are prepared; and
5. the user explicitly approves production execution.
