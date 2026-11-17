# Factoori shared database — draft package

> **DRAFT ONLY — NOT APPLIED TO ANY SUPABASE DATABASE.** These files are a design artifact on the isolated branch `work/factoori-shared-db-schema`. They must be reviewed, tested against a disposable Supabase branch, and reconciled with the live license subsystem before any production migration.

## Target
One Supabase Auth identity shared by Android and the Factoori website. Every operational row belongs to a `business_id`; a user may belong to multiple businesses. PostgreSQL RLS is the tenant boundary. Sensitive cost data is separated from ordinary catalog/document rows.

## Existing production objects preserved
The current public license tables and the current license Edge Functions/RPCs are out of scope for these drafts. In particular, do not rename, drop, rewrite, or change grants on `app_licenses`, `factori_license_keys`, `factori_license_activations`, `factori_license_nonces`, `activate_license`, `factori_issue_order_license`, or deployed Edge Functions as part of this schema package.

## Draft files
1. `001_identity_permissions.sql` — profiles, businesses, memberships, permission catalog and private authorization helpers.
2. `002_contacts_catalog_documents.sql` — contacts, products, services, warehouses, documents and immutable document lines.
3. `003_finance_inventory_accounting.sql` — transactions, allocations, cheques, stock ledger and double-entry ledger.
4. `004_settings_sync_migration.sql` — settings, subscriptions/entitlements, sync and legacy migration staging.
5. `005_rls_grants_validation.sql` — RLS policies, least-privilege grants and transactional helper RPCs.
6. `006_validation.sql` — read-only schema, RLS, ledger, stock and allocation checks.
7. `RPC_CONTRACTS.md` — required transactional API contracts.
8. `TEST_MATRIX.md` — end-to-end security, finance, inventory and migration test matrix.
9. `STORAGE_POLICIES.md` — private bucket and tenant-scoped attachment policy design.

## Decisions encoded provisionally
- Money is stored as integer IRR (Rial) in the new canonical model; legacy records carry source currency/unit metadata and are not converted until the business-level historical unit is established.
- Quantity uses `numeric(20,4)`; money uses `bigint` with explicit currency code.
- Product costs, document cost snapshots, stock movement costs, inventory valuations and FIFO layers are isolated in private tables. A sales role must not infer margin from API-visible fields.
- Documents become immutable at `posted`; correction is via reversal/corrective documents. Account transfers, cheque assignment events and service-document total-cost snapshots have dedicated structures.
- Stock movements and journal lines are append-only after posting.
- Weighted-average costing is the initial *candidate*, not yet an irreversible business setting. The schema retains `costing_method` to support FIFO if selected.
- Numbering is atomic per business, document type and fiscal period; reset behavior is explicit.
- No uniqueness constraint is imposed on phone numbers.
- User/device presentation preferences are scoped to the authenticated user and device; biometric enrollment secrets remain in the OS secure keystore.
- Legacy `db:v2` imports preserve raw payloads, currency metadata and ambiguous rows for review.
- License purchase, device activation, business ownership and entitlement are separate concepts.

## Important deployment caveat
Supabase announced that newly created public tables are no longer automatically exposed through the Data API (enforced on existing projects from 2026-10-30). Explicit API exposure/grants must be configured intentionally. RLS is still mandatory for exposed tables. These drafts do not alter the current project's API exposure settings.

## Automated draft validation

The branch includes a GitHub Actions workflow that applies the draft migrations to an isolated PostgreSQL 17 service, runs synthetic Auth/RLS/entitlement/quota smoke tests, then executes the read-only validation queries. It does not connect to or modify the production Supabase project.

## Required validation before production
- Apply to a disposable Supabase branch, never directly to production.
- Run SQL parse/migration tests, pgTAP authorization tests and Supabase Security/Performance Advisors.
- Test owner/admin/accountant/sales/viewer and cross-business isolation.
- Test concurrent invoice numbering, stock deduction, cheque allocation and payment allocation.
- Reconcile legacy customer balances, supplier balances, cash/bank balances, cheques, inventory and historical gross profit.
- Resolve the open decisions in `DECISIONS.md` before final production migration.
