# Shared database migration drafts

These files are **not production migrations**. They live under `supabase/drafts/` intentionally and have not been applied to the live Supabase project.

## Draft order

1. `001_identity_business_permissions.sql` — profiles, businesses, memberships, role defaults, permission helpers, business settings, and the initial Auth/RPC integration.
2. `002_core_documents.sql` — tenant-scoped contacts, warehouses, fiscal periods, document headers/items, and draft-only document creation.
3. `003_financial_ledger.sql` — accounts, receipts/payments, allocations, cheques, contact ledger and journal primitives.
4. `004_catalog_inventory.sql` — products/services, protected cost snapshots, stock movements, transfers and costing layers.
5. `004a_sync_infrastructure.sql` — sync device/cursor/operation tables and initial Free-tier quota enforcement.
6. `005_sync_compatibility.sql` — legacy compatibility sync transport; **not production-ready** and depends on additional sync schema/functions not yet delivered.
7. `006_journal_integrity.sql` — database guards for balanced, immutable posted journal entries.

## Test scripts

- `supabase/tests/001_identity_business_permissions.sql`
- `supabase/tests/002_core_documents.sql`
- `supabase/tests/003_financial_ledger.sql`
- `supabase/tests/004_catalog_inventory.sql`
- `supabase/tests/004a_sync_infrastructure.sql`
- `supabase/tests/005_sync_compatibility.sql`
- `supabase/tests/006_journal_integrity.sql`

The test scripts are designed for an isolated disposable Supabase/Postgres project after applying the corresponding draft migrations. They have not been run against production.

## Deliberately not included yet

- Invoice numbering sequences and complete fiscal close/reopen controls
- Posting/reversal RPCs and cheque assignment lifecycle (journal integrity guards are drafted, but the posting engine is not)
- Server-side stock mutation RPCs and inventory balance projections
- Invitations, audited member management and owner transfer
- Subscription entitlements and server-enforced free/pro quotas
- Offline sync device registry, cursors, operation log and conflict handling
- Legacy `db:v2` import/reconciliation and migration id mapping
- Private cheque-image storage and SMS retention policy

## Release gate

Do not move these drafts into `supabase/migrations/` or run them against the live project until:
1. schema dependencies and exact RPC signatures are reconciled;
2. SQL syntax and tests pass in a disposable staging project;
3. cross-business RLS, permission matrix, concurrency, idempotency and data reconciliation tests pass;
4. rollback/restore plan and a complete migration package are prepared; and
5. the user explicitly approves production execution.
