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
17. `016_accounting_defaults.sql` — tenant-scoped default chart of accounts, default cash account, and financial-account ledger mapping for new and existing businesses.
18. `017_customer_receipt_posting.sql` — atomic customer receipt, optional posted-invoice allocation, customer advance accounting, contact ledger, and balanced journal posting.
19. `018_simple_financial_posting.sql` — atomic supplier payments, expense payments, and other income with contact ledger where applicable and balanced journal posting.
20. `019_purchase_document_posting.sql` — atomic purchase-document posting with warehouse stock movements, FIFO cost layers, protected cost snapshots, supplier ledger, and balanced journal.
21. `020_goods_sale_posting.sql` — atomic goods-sale posting with FIFO layer consumption, cost allocations, customer ledger, revenue/tax/COGS/inventory journal and idempotency.
22. `021_fifo_warehouse_transfers.sql` — replaces quantity-only stock transfers with FIFO-layer movement and preserved cost provenance.
23. `022_inventory_opening_posting.sql` — posts valued opening stock into warehouse movements, FIFO layers, product cost history, and opening-equity journal atomically.
24. `023_inventory_wastage_posting.sql` — posts wastage as FIFO stock consumption, cost allocations and an expense/inventory write-off journal.

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

The workflow starts a disposable PostgreSQL 17 service in the GitHub-hosted runner, creates only the minimal `auth.users` table, `auth.uid()` function and Supabase role names needed by these drafts, applies all twenty-four draft migrations in dependency order (013 is applied after a test-only license-schema fixture), then runs all twenty-six SQL regression scripts. It does **not** connect to, create, or modify any Supabase project and does not require Supabase branching or a paid database.

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
- `supabase/tests/016_accounting_defaults.sql`
- `supabase/tests/017_customer_receipt_posting.sql`
- `supabase/tests/018_simple_financial_posting.sql`
- `supabase/tests/019_purchase_document_posting.sql`
- `supabase/tests/020_goods_sale_posting.sql`
- `supabase/tests/021_fifo_warehouse_transfers.sql`
- `supabase/tests/022_inventory_opening_posting.sql`
- `supabase/tests/023_inventory_wastage_posting.sql`

## Device proof deployment note

Migration 009, the `prove-sync-device` Edge Function source, and the Android/Web client key-challenge helpers are implemented on this development branch. The function is configured with gateway JWT verification and also validates the user's access token itself. Its cryptographic helper has Deno unit tests and the Edge Function is type-checked in CI. **The Edge Function has not been deployed to the live Supabase project**, and migration 009 has not been applied there.

## Deliberately not included yet

- Invoice numbering sequences and complete fiscal close/reopen controls
- Journal reversal RPC, cheque lifecycle posting/assignment, normalized invoice-to-ledger posting and purchase/expense/receipt RPCs
- Full inventory adjustment/purchase/sale posting RPCs and materialized inventory balance projections
- Sales returns, purchase returns, refunds, cheque lifecycle, (purchase posting is in 019, goods-sale posting in 020, FIFO-layer warehouse transfers in 021, valued opening-stock provisioning in 022, and FIFO-valued wastage posting in 023)
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


## Accounting defaults (016)

Migration 016 seeds a minimal system chart of accounts for every business, creates a zero-balance default cash account only when the business has no active default financial account, and maps active financial accounts to chart accounts by explicit account type. It runs on business creation and backfills existing businesses. It does not create opening balances, journal entries, or financial transactions. Existing account mappings are never overwritten. Test 016 verifies per-business account separation, cash mapping, zero opening balance, and initializer idempotency.


## Customer receipt posting (017)

Migration 017 adds `public.post_customer_receipt(...)`. It requires `payments.create`, validates a same-business active customer and a mapped same-currency financial account, serializes idempotency keys, optionally allocates part or all of the receipt to a posted sales document, and atomically creates the financial transaction, allocation, customer ledger credit, and balanced posted journal. Unallocated amounts are credited to the customer-advances liability account (2200), not incorrectly booked as receivables. A repeated identical request returns the original transaction; reusing the key with changed data fails. Test 017 covers partial allocation, advances, balanced journal, customer ledger, idempotency and cross-business denial.


## Simple financial posting (018)

Migration 018 adds `public.post_simple_financial_transaction(...)` for the controlled transaction types `supplier_payment`, `expense_payment`, and `other_income`. It derives the direction and counterpart ledger account server-side (2000, 6000, or 7000), validates contact type for supplier payments, requires the correct permission, validates the mapped same-currency cash/bank account, and atomically writes the financial transaction and a balanced posted journal. Supplier payments also write a debit to the supplier contact ledger. Arbitrary chart-account selection is not accepted from the client. Test 018 covers all three types, idempotent replay, changed-payload rejection, journal balance, supplier ledger and tenant isolation.


## Purchase document posting (019)

Migration 019 adds `public.post_purchase_document(uuid,uuid,text)` and a private-by-default `document_postings` ledger. It only posts draft purchase documents after validating supplier, warehouse, product ownership, quantities, discounts, tax and exact header/line reconciliation. The operation atomically creates purchase stock movements, FIFO cost layers, protected document-item cost snapshots, product cost history, supplier contact-ledger credit, and a balanced journal (inventory + recoverable purchase tax against supplier payable). It uses row locks, a business-scoped idempotency key, and a document-level uniqueness guard. It does not create cash payments; supplier settlement is a separate operation through migration 018. Test 019 covers inventory layer creation, costs, supplier balance, journal balance, idempotent replay and tenant isolation.


## Goods-sale posting (020)

Migration 020 adds `public.post_goods_sale_document(uuid,uuid,text)`. It validates a draft goods-sale document and its exact header/line/tax totals, locks products and FIFO layers, consumes stock from the selected warehouse, writes stock movements and cost allocations, stores protected item cost snapshots, and atomically posts receivable, sales revenue, output tax, COGS and inventory journal lines plus the customer ledger debit. It fails closed when FIFO layers are insufficient; it does not fabricate cost from a product's current display price. Goods transferred between warehouses or brought in through opening balances still need FIFO-layer provisioning before they can be sold. Test 020 covers a purchase-to-sale lifecycle, FIFO consumption, journal balance, customer ledger, idempotency and tenant isolation.


## FIFO warehouse transfers (021)

Migration 021 replaces the earlier quantity-only `post_stock_transfer` implementation. It requires both movement balance and FIFO layer balance to cover the transfer, locks products and warehouses, consumes source layers in FIFO order, records transfer-out cost allocations, and creates destination layers that preserve original unit cost and acquisition timestamp. This prevents a transfer from creating stock that cannot later be costed on sale. It fails closed when legacy/adjustment stock has no reconciled FIFO layer. Test 021 posts a purchase, transfers part of its FIFO layer, and sells from the destination warehouse at the preserved cost.


## Valued inventory opening (022)

Migration 022 adds `public.post_inventory_opening(uuid,date,text,jsonb,text)`. It accepts product/warehouse/quantity/unit-cost lines, rejects duplicates and any product/warehouse pair that already has stock history, locks products and warehouses, and atomically creates opening stock movements, FIFO cost layers, protected product-cost history, and a balanced journal (debit inventory 1200 / credit owner equity 3000). The RPC is permission-gated by `inventory.adjust`, idempotent by request fingerprint, and fails closed for zero or missing cost. Opening stock is not fabricated from product display price or legacy quantity alone. Test 022 covers stock/layer creation, valuation, balanced journal, idempotent retry, changed-key rejection, duplicate-opening rejection and tenant isolation.


## Inventory wastage posting (023)

Migration 023 adds `public.post_inventory_wastage(uuid,date,text,jsonb,text)`. It validates and locks the affected products/warehouses, checks both stock movement and FIFO-layer availability before writing, creates negative wastage movements, consumes cost layers FIFO, records cost allocations, and posts the write-off to operating expense (6000) against inventory (1200). Zero-cost stock is allowed and does not create an invalid zero-value journal. The operation is idempotent, tenant-scoped and permission-gated. Test 023 covers purchase-to-wastage cost consumption, remaining quantity, balanced journal, insufficient stock, retry and cross-business denial.
