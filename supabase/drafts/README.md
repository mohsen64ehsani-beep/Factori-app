# Shared database migration source and deployment status

The SQL source files remain under `supabase/drafts/` as the tested development sequence. On 2026-11-18, all 37 database changes (001–036, including 004a) were applied successfully to the live Factoori Supabase project. Matching, timestamped copies are recorded under `supabase/migrations/` so the GitHub branch tracks the production migration history. The two earlier license migrations remain the pre-existing production baseline.

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
25. `024_legacy_reference_import.sql` — owner-authorized, fingerprinted import of legacy customers and products only; excludes sensitive cost, stock quantities, documents and financial data.
26. `025_legacy_catalog_warehouse_import.sql` — imports legacy category labels, service names and warehouses with stable mapping; never imports warehouse quantities or stock movements.
27. `026_legacy_goods_invoice_draft_import.sql` — imports legacy goods invoices as normalized drafts only; excludes posting, stock, payments, journals and protected legacy cost snapshots.
28. `027_legacy_service_invoice_draft_import.sql` — imports legacy service invoices as normalized drafts only; excludes service costs and separate initial payments.
29. `028_legacy_reconciliation_gate.sql` — read-only reconciliation counts and cutover gate across supported imports and deferred financial collections.
30. `029_legacy_supplier_contact_import.sql` — extends the private identity map and imports legacy supplier contacts; does not import purchase invoices or supplier payments.
31. `030_legacy_fiscal_period_import.sql` — imports legacy fiscal lock ranges as closed normalized periods, preserving edit restrictions.
32. `031_service_document_posting.sql` — atomically posts service sales and service purchases to the ledger without fabricating stock or service-cost allocations.
33. `032_cheque_lifecycle_posting.sql` — creates cheques, records lifecycle events and posts settlement only on clearing.
34. `033_cheque_reversal_posting.sql` — reverses cleared cheque settlements with linked, balanced journal entries.
35. `034_sales_return_posting.sql` — posts invoice-linked goods sales returns and restores original FIFO costs.
36. `035_customer_refund_posting.sql` — pays cash refunds against posted sales returns within customer credit.
37. `036_purchase_return_posting.sql` — posts invoice-linked goods purchase returns from the original FIFO layer and caps supplier cash refunds.
38. `037_web_catalog_crud.sql` — grants permission-checked authenticated create/update access to contacts, products and services for the web workspace; hard deletes remain disabled.
39. `038_rls_initplan_optimization.sql` — changes three auth RLS predicates to scalar subselects to avoid per-row auth.uid() evaluation.
40. `039_bidirectional_master_sync.sql` — bridges customer, supplier and product records both ways between normalized web tables and the Android legacy sync stream.
41. `040_product_sync_fields.sql` — preserves SKU and inventory-tracking fields when product records cross the mobile/web bridge.
42. `041_sales_invoice_mobile_bridge.sql` — mirrors normalized web goods-sale drafts into the Android `inv` sync stream and exposes mobile-origin invoices to web.
43. `042_invoice_bridge_warehouse_fix.sql` — removes an unsupported legacy warehouse lookup and safely handles non-numeric document numbers.

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

The workflow starts a disposable PostgreSQL 17 service in the GitHub-hosted runner, creates only the minimal `auth.users` table, `auth.uid()` function and Supabase role names needed by these drafts, applies all forty-three draft migrations in dependency order (013 is applied after a test-only license-schema fixture), then runs all forty-five SQL regression scripts. It does **not** connect to, create, or modify any Supabase project and does not require Supabase branching or a paid database.

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
- `supabase/tests/024_legacy_reference_import.sql`
- `supabase/tests/025_legacy_catalog_warehouse_import.sql`
- `supabase/tests/026_legacy_goods_invoice_draft_import.sql`
- `supabase/tests/027_legacy_service_invoice_draft_import.sql`
- `supabase/tests/028_legacy_reconciliation_gate.sql`
- `supabase/tests/029_legacy_supplier_contact_import.sql`
- `supabase/tests/030_legacy_fiscal_period_import.sql`
- `supabase/tests/031_service_document_posting.sql`
- `supabase/tests/032_cheque_lifecycle_posting.sql`
- `supabase/tests/033_cheque_reversal_posting.sql`
- `supabase/tests/034_sales_return_posting.sql`
- `supabase/tests/035_customer_refund_posting.sql`
- `supabase/tests/036_purchase_return_posting.sql`
- `supabase/tests/037_web_catalog_crud.sql`
- `supabase/tests/038_rls_initplan_optimization.sql`
- `supabase/tests/039_bidirectional_master_sync.sql`
- `supabase/tests/040_product_sync_fields.sql`
- `supabase/tests/041_sales_invoice_mobile_bridge.sql`
- `supabase/tests/042_invoice_bridge_warehouse_fix.sql`

## Device proof deployment note

Migration 009, the `prove-sync-device` Edge Function source, and the Android/Web client key-challenge helpers are implemented on this development branch. The function is configured with gateway JWT verification and also validates the user's access token itself. Its cryptographic helper has Deno unit tests and the Edge Function is type-checked in CI. **The Edge Function has not been deployed to the live Supabase project**, and migration 009 has not been applied there.

## Deliberately not included yet

- Invoice numbering sequences and complete fiscal close/reopen controls
- General journal reversal, cheque transfer/assignment, invoice numbering and complete fiscal close/reopen controls
- Broader inventory adjustment workflows and materialized inventory balance projections
- Service returns and legacy return records without original invoice-item links; goods sales returns and customer refunds are in 034–035, while goods purchase returns and supplier refunds are in 036
- Owner transfer, account deletion/retention and owner recovery
- Verified subscription upgrades, downgrades, grace periods and paid-plan entitlements
- Full multi-device sync runtime tests and normalized financial sync operations
- Legacy `db:v2` normalized writes, import execution, and transactional financial/stock reconciliation (014 adds only the private identity map; 015 adds only a read-only preflight audit)
- Private cheque-image storage and SMS retention policy

## Release gate

Do not re-apply the already-deployed sequence. For future database changes, create a new migration and validate it in CI before production deployment. The existing production sequence was applied after explicit project-owner authorization. Remaining release gates are:
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


## Legacy reference-data import (024)

Migration 024 adds `public.import_legacy_reference_data(uuid,uuid)`, a business-owner-authorized import for legacy `cust` and `prod` rows only. It reads only `payload_public`, validates the legacy ID and required name, fingerprints each source row, and records target UUIDs in the private mapping ledger. Identical reruns are no-ops; changed source rows are marked `conflict` and never silently overwrite normalized records; missing mapped targets are marked `orphaned`. Product `buy`/cost fields remain in the private source payload and are not read or copied, and product `qty` is deliberately ignored: no stock movement, FIFO layer or product cost is created. Tombstoned rows are skipped. Barcode uniqueness collisions are reported as conflicts. Categories, warehouses, services, draft invoices and all financial/stock collections remain outside this first importer. Test 024 covers customer/product mapping, rerun idempotency, changed-source conflict, skipped tombstones, sensitive cost/quantity exclusion and cross-business denial.


## Legacy catalog and warehouse import (025)

Migration 025 adds `public.import_legacy_catalog_and_warehouses(uuid,uuid)`. It normalizes the app's primitive category/service strings using their sync identity `value:<text>`, and imports warehouse objects using their legacy string IDs mapped to newly generated normalized UUIDs. The first active legacy warehouse becomes the default only when the business has no active default. Products are linked to a category only by an exact label match and only when their normalized category is still unset. Repeated imports are no-ops; changed rows are flagged as conflicts; ambiguous existing warehouse matches are not silently linked. No warehouse stock quantities, stock movements, FIFO layers, product costs, or financial data are imported. Test 025 verifies primitive collection identities, generated warehouse IDs, exact product-category linking, default warehouse behavior, idempotency, source-change conflict and tenant isolation.


## Legacy goods invoice draft import (026)

Migration 026 adds `public.import_legacy_goods_invoice_drafts(uuid,uuid)`. It resolves the legacy customer, product and optional warehouse through the private mapping ledger, validates the date, invoice number, item count, quantities, prices, discount and tax, and calls the normalized draft-document RPC. Imported invoices remain `draft`; the legacy bank account, payments, item cost (`b`), stock quantity and financial postings are intentionally ignored. The importer fingerprints the sanitized public payload, makes identical reruns no-ops, and marks changed source invoices as conflicts rather than overwriting normalized drafts. Test 026 covers exact draft totals and item snapshots, idempotency, source-change conflict, cross-business denial, and absence of cost, stock, journal and posting records.


## Legacy service invoice draft import (027)

Migration 027 adds `public.import_legacy_service_invoice_drafts(uuid,uuid)`. It resolves customer and service references through the private mapping ledger, validates invoice date/number, item descriptions, quantities, prices and discount, and creates a normalized `service_sale` draft. Legacy service costs (`cost`, `costTotal`, `costMode`) are never read, and the separate `pay` collection is not imported. Repeated imports are no-ops; changed source invoices are flagged as conflicts. Test 027 verifies the normalized draft and totals, service mapping, idempotency, changed-source conflict, tenant isolation, and absence of payments, journals, cost snapshots and stock movements.


## Legacy reconciliation gate (028)

Migration 028 adds `public.reconcile_legacy_normalization(uuid)`, a read-only, business-admin-only report. It returns per-collection counts for active/deleted source rows, current mappings, unmapped rows, changed fingerprints, conflicts, orphaned mappings and records needing review. It separately counts deferred financial/stock collections and mapped invoice drafts still awaiting user review. It returns no customer names, phone numbers, source payloads, product costs or financial details. `safe_to_cutover` remains false while any unresolved source/mapping row, deferred financial row or imported draft awaiting review exists. Test 028 verifies read-only behavior, source-change detection, deferred financial visibility, payload privacy and tenant isolation.


## Legacy supplier contact import (029)

Migration 029 extends the private legacy identity-map collection allowlist with `suppliers` and adds `public.import_legacy_supplier_contacts(uuid,uuid)`. It imports supplier name, phone and address as normalized `contacts` with `contact_type='supplier'`, using source fingerprints and the same no-overwrite conflict behavior as customer import. Purchase documents and supplier payments remain deferred. The preflight now validates supplier source identity and reports purchases that reference missing suppliers; the reconciliation gate includes suppliers and separately counts deferred bank-account, fiscal-period, due-date and SMS-history collections. Test 029 verifies mapping, idempotency, changed-source conflict, tenant isolation and the absence of financial postings.


## Legacy fiscal period import (030)

Migration 030 adds `public.import_legacy_fiscal_periods(uuid,uuid)`. Legacy `fiscal` records contain a title and inclusive `from`/`to` dates; each is mapped to a normalized `fiscal_periods` row with `status='closed'`, preserving the old app's date-lock behavior. Invalid ranges, overlapping periods and duplicate targets are not silently imported. Repeated imports are no-ops and changed source rows become conflicts. Test 030 verifies closed status, idempotency, source-change conflict and tenant isolation.


## Service document posting (031)

Migration 031 adds `public.post_service_document(uuid,uuid,text)` for draft `service_sale` and `service_purchase` documents. It validates the same-business active customer/supplier and service catalog rows, exact line/header/tax totals, fiscal-period status, and idempotency. Service sales debit receivables and credit service revenue/output tax; service purchases debit direct service expense/recoverable input tax and credit supplier payable. Both create a contact-ledger entry and a balanced posted journal atomically. The RPC deliberately creates no stock movement or service-cost snapshot because the legacy app's service-cost fields remain excluded from import. Test 031 covers both directions, balanced journals, contact ledgers, replay, duplicate posting denial, tenant isolation, and absence of fabricated stock/cost data.


## Service document posting (031)

Migration 031 adds `public.post_service_document(uuid,uuid,text)` for normalized `service_sale` and `service_purchase` drafts. It validates service-only lines, customer/supplier role, document totals, tax and fiscal-period state; then atomically posts balanced journal lines and the appropriate customer/supplier ledger entry. Service sales debit receivables and credit service revenue/tax payable; service purchases debit service expense and recoverable tax and credit supplier payables. It intentionally creates no stock movements, inventory layers, item-cost allocations or cash transactions. Test 031 covers both directions, journal balance, contact ledgers, idempotent replay, rejection of reposting under a new key, cross-business denial and no fabricated inventory costs.


## Cheque lifecycle and settlement (032)

Migration 032 adds `public.create_cheque(...)` and `public.transition_cheque(...)`. Cheque creation is fingerprinted and idempotent, validates same-business customer/supplier ownership, Sayad ID format and date/amount fields, and records a `created` event. Allowed pre-settlement transitions are audited (`pending` to `deposited`, `bounced`, `cancelled` or `returned`; received `deposited` to `cleared`, `bounced`, `cancelled` or `returned`; issued `pending` to `cleared`, `bounced` or `cancelled`). Clearing a received cheque posts a normal customer receipt; clearing an issued cheque posts a normal supplier payment. The transaction and cheque event/status update are atomic. A cheque already cleared cannot be marked bounced/returned by status edit; it requires a separate audited reversal flow, which remains a release gate. Test 032 covers idempotent creation/event replay, deposit without premature cash posting, received and issued cheque settlement, bounced-before-clear behavior and tenant isolation.


## Cleared-cheque reversal (033)

Migration 033 adds `public.reverse_cleared_cheque(uuid,uuid,date,text,text)`. It is separate from ordinary status transitions: it locks the cheque, validates the original posted settlement transaction and journal, copies the original journal lines with debit/credit reversed, links the new journal through `reverses_entry_id`, writes a reversal financial transaction and the opposite contact-ledger entry, stores a private one-to-one reversal record, and only then changes the cheque to `bounced`. The original transaction and journal remain intact; the reversal is a new auditable event. Test 033 covers both received and issued cheque reversals, journal balance, contact-ledger direction, idempotent replay and tenant isolation.


## Invoice-linked goods sales returns (034)

Migration 034 adds `public.post_sales_return(uuid,uuid,date,jsonb,text,text)`. Each return line must reference an item on the exact original posted goods-sale document; quantities cannot exceed the unreturned original line quantity. Return taxable value and tax are derived proportionally from the original line and its allocated header discount, with cumulative rounding so the final return reconciles exactly. The RPC restores inventory into the original sale warehouse by recreating FIFO cost layers at the original allocation costs, and privately tracks how much of each original cost allocation has already been returned. It posts a balanced credit-note journal (revenue/tax reduction, customer receivable credit, and inventory/COGS restoration) and a customer-ledger credit atomically. It does not issue cash refunds; those are separate settlement operations. Legacy `returns` rows that lack an original invoice-item reference remain deferred and must be matched manually before import. Test 034 covers purchase-to-sale-to-partial-return lifecycle, FIFO cost restoration, idempotency, full return limits, journal balance and tenant isolation.


## Customer cash refunds (035)

Migration 035 adds `public.post_customer_refund(...)` for settling a posted goods-sales return. A refund is capped by both the unrefunded return amount and the customer's net credit balance, so an unpaid original invoice cannot be refunded prematurely. It validates a same-currency mapped cash/bank account, creates a customer-refund financial transaction, debits receivables, credits cash/bank, writes the customer-ledger debit, and updates `sales_return_documents.refunded_amount` in one idempotent transaction. Test 035 covers blocking refunds while the original sale remains unpaid, partial refund, retry, final refund, over-refund prevention, balanced journal, and tenant isolation.


## Invoice-linked purchase returns and supplier cash refunds (036)

Migration 036 adds `public.post_purchase_return(...)` and `public.post_supplier_refund(...)`. A purchase return must reference a line on the exact original posted goods-purchase invoice. Returned quantity is capped by both the unreturned invoice quantity and the remaining quantity in that invoice line's original FIFO layer in its source warehouse; stock already sold, transferred, wasted, or otherwise consumed cannot be returned through this path. Return value and tax are derived cumulatively from the original line and allocated header discount. The FIFO layer cost must reconcile exactly with the protected original item-cost snapshot; mismatches fail closed for manual review instead of creating a balancing plug. Posting writes the negative stock movement, original-layer cost allocation, supplier debit, and balanced payable/inventory/input-tax journal atomically. Supplier cash refunds are capped by both the unrefunded purchase-return amount and the supplier's net debit balance, require a same-currency mapped financial account, and write an idempotent financial transaction, balanced journal, and supplier-ledger credit. Test 036 covers FIFO reduction, tax/value reconciliation, retry, over-return prevention, premature and excessive supplier refunds, balanced journals, and tenant isolation.


## WordPress web accounting workspace (0.1.0)

The companion plugin source is in `wordpress-plugin/factoori-web-accounting/`. It provides a dedicated full-screen shortcode page, shared Supabase Auth login/registration, business selection/creation, contact and product management, sales draft creation, and supported document posting through validated RPCs. The browser uses only the Supabase Publishable key; service-role credentials are never embedded. The plugin package workflow is `.github/workflows/build-factoori-web-plugin.yml`.


## RLS performance follow-up (038)

Migration 038 updates the self-profile and membership read policies to use scalar `select auth.uid()` expressions. The live performance advisor no longer reports the corresponding three `auth_rls_initplan` warnings after this migration.


## Bidirectional web/mobile master-data bridge (039)

Web-created customers, suppliers and products are written to the same `business_state_records` stream consumed by Android sync. Records pushed by Android into that stream are projected into the normalized `contacts` and `products` tables used by the web workspace. Direct REST inserts/updates are revoked; the web uses permission-checked RPCs with Freemium limits so writes cannot bypass the sync stream or quota checks.


## Sales invoice sync bridge (041–042)

Normalized web goods-sale drafts receive a mobile-compatible document number and are mirrored to the Android `inv` sync collection. Android-origin invoice records are exposed to the web workspace through a permission-checked read RPC. Legacy mobile invoices remain marked as app-origin records until the owner completes the normalized import/reconciliation workflow; the web UI does not post those records directly.
