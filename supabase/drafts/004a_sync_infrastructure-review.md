# 004a sync infrastructure and quotas — review gates

Status: DEVELOPMENT DRAFT ONLY — NOT EXECUTED.

Defines predecessor tables required by compatibility sync: device registry, per-device cursors, idempotent operation log, business revision stream, and per-business feature entitlements/usage. It seeds initial Free-tier defaults when a business is created.

## Initial Free-tier defaults
- 3 new invoices per business-local day
- 10 items per invoice
- 50 customers
- 50 products
- 50 services
- 1 warehouse

## Important implementation details
- Device, cursor, operation, revision and quota tables have RLS enabled and no direct client grants.
- A unique constraint protects (business_id, device_id, operation_id).
- Member permission versions increment on role/status changes and per-member permission override changes; each sync device stores the version it last acknowledged.
- The daily quota row is locked during consumption; duplicate operation IDs do not consume quota twice.
- Lifetime catalog limits count non-deleted records in the compatibility state table. The function is defined before migration 005 creates that table; its SQL body resolves the relation when first invoked after 005 is installed.
- The trigger seeds default limits for new businesses; existing businesses are backfilled without overwriting configured values.
- Private quota functions are callable only from trusted owner-context functions; no direct authenticated grants are made.

## Blocking work
1. Test new-business trigger ordering against the Auth/business creation flow.
2. Verify the compatibility state table exists before invoking lifetime count limits.
3. Add the same limits to normalized product/customer/service RPCs.
4. Add a privileged subscription/entitlement RPC to replace Free defaults only after verified payment.
5. Add reset/upgrade/downgrade behavior, grace periods, and concurrency tests.
6. Add device key proof-of-possession and device revocation controls.
7. Test quota races across multiple devices and local timezone boundaries.
8. Verify permission-version triggers bump only the affected member and that devices are forced to reset after permission changes.

The defaults are draft policy, not an active production subscription system.
