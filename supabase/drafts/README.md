# Shared database migration drafts

These files are **not production migrations**. They live under `supabase/drafts/` intentionally and have not been applied to the live Supabase project.

## Draft order

1. `001_identity_business_permissions.sql` — profiles, businesses, memberships, role defaults, permission helpers, business settings, and the initial Auth/RPC integration.
2. `002_core_documents.sql` — tenant-scoped contacts, warehouses, fiscal periods, document headers/items, and draft-only document creation.
3. `005_sync_compatibility.sql` — legacy compatibility sync transport; **not production-ready** and depends on additional sync schema/functions not yet delivered.

## Test scripts

- `supabase/tests/001_identity_business_permissions.sql`
- `supabase/tests/002_core_documents.sql`

The test scripts are designed for an isolated disposable Supabase/Postgres project after applying the corresponding draft migrations. They have not been run against production.

## Deliberately not included yet

- Normalized product/service catalog and private cost snapshots
- Invoice numbering sequences and complete fiscal close/reopen controls
- Journal entries, chart of accounts, posting/reversal RPCs
- Inventory movement ledger and cost layers
- Financial transactions, allocations, cheques and assignment lifecycle
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
