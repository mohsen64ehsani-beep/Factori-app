# Legacy db:v2 to normalized accounting bridge

Status: mapping foundation and read-only preflight are implemented as development drafts (014/015) and covered by isolated PostgreSQL CI. No importer exists yet; no production data or live Supabase schema has been changed.

## Why a bridge is required

The Android application persists a JSON object under `db:v2` (or the business-scoped `db:v2:business:<id>` key). The compatibility sync stores records in `private.business_state_records`, keyed by business, collection, and legacy ID. The normalized accounting schema instead uses relational tables such as `contacts`, `products`, `documents`, `document_items`, `financial_transactions`, and `stock_movements`.

These are two different representations. A successful generic sync is not evidence that a normalized accounting record exists. Financial and stock collections remain blocked for generic writes; that restriction must stay in place until dedicated transactional RPCs exist.

## Confirmed legacy shapes from the active app source

The app's initial database object declares these collections: `cust`, `prod`, `inv`, `pay`, `debt`, `creditors`, `creditorPayments`, `expenses`, `services`, `serviceInv`, `categories`, `stockMoves`, `suppliers`, `purchases`, `supplierPayments`, `returns`, `wastage`, `warehouses`, `transfers`, `accounts`, `moneytransfers`, `otherincome`, `opening`, `fiscal`, `duedates`, `warehouseStocks`, `smsHistory`, and `bankAccounts`. Optional advanced settings are object-shaped and must not be copied wholesale into generic sync.

The following row fields are directly confirmed in the app source:

### Customers (`cust`)

- `id`: stable legacy identity
- `n`: display name
- `ph`: phone
- `ad`: address
- `code`: customer code / national identifier field as currently labelled by the app

Target: `public.contacts`, with `contact_type='customer'`, `legacy_id=String(id)`, and direct name/phone/address/code mapping. Do not infer a legal identity type from `code`.

### Products (`prod`)

- `id`: stable legacy identity
- `n`: name
- `category`: legacy category label
- `buy`: purchase cost (sensitive)
- `sell`: sale price
- `qty`: current on-hand quantity
- Other observed optional fields include `barcode` and `minQty`.

Target: `public.products` for name, sale price, barcode, minimum stock, and category relation. Map category by a business-scoped legacy mapping, not by label alone. Store `buy` only through the protected cost path (`public.product_costs`) after the caller's cost permission is verified. Do not place cost in public product payloads.

Important: `qty` is a balance, not a movement. It must not be copied into a product column or converted into a stock movement until the source opening date, warehouse assignment, and existing movement history are reconciled. Otherwise importing it could double-count stock.

### Goods invoices (`inv`)

Confirmed header fields include `id`, `no`, `dt`, `createdAt`, `cid`, `bankAccountId`, `warehouseId`, `items`, `ds`, and `tx`. Item rows include `pid`, `n`, `q`, `p`, and `b`.

Target: `public.documents` with `document_type='goods_sale'`, `status='draft'`, business-scoped contact/warehouse references, and `public.document_items` snapshots. Resolve product IDs through the mapping table. Preserve the item description snapshot even if the original product is later renamed. Store item cost snapshots only in the protected cost table and only for authorized imports.

The app's current legacy invoice object does not itself prove that an invoice is posted in the normalized ledger. Importing a legacy invoice must therefore create a draft and must not create journal entries, financial transactions, customer-ledger entries, or stock movements.

### Services and service invoices

The current app source confirms that `services` is a list of service-description strings, not objects. The persisted `serviceInv` row is `{id,no,dt,createdAt,cid,bankAccountId,items,discount,costMode,costTotal}`. Each item is `{desc,qty,price,cost}`. `cost` and `costTotal` are sensitive and must never be returned in ordinary client-readable payloads. Initial paid amounts are represented separately in `pay` with `source='service_invoice'` and `invoiceId`; they must not be imported through a draft-document importer. Service catalog normalization needs a deterministic business-scoped name mapping because legacy service rows have no stable IDs. The exact persisted warehouse shape and category semantics still require source audit.

Target candidates are `public.services`, `public.documents` with `document_type='service_sale'`, and `public.document_items` with `item_type='service'`. Cost fields must remain protected.

## Required mapping ledger

The bridge should use a private mapping table with a uniqueness constraint on:

`(business_id, legacy_collection, legacy_id)`

Each mapping row should retain the normalized table/entity type, normalized UUID, source payload fingerprint, import state, and timestamps. It must never assume that a legacy string ID is a UUID. Re-running an import with the same source fingerprint must be a no-op; a changed source row must be reconciled as an update or surfaced as a conflict, never silently duplicated.

The mapping ledger must be business-scoped and inaccessible to `anon`. Client writes should go through narrowly scoped RPCs with explicit membership and permission checks. Any privileged function must use a fixed search path, narrowly scoped grants, validated ownership, and sanitized errors.

## Import phases and release rules

1. **Inventory/preflight (read-only):** count source rows by collection; validate row shapes; detect duplicate or missing legacy IDs; identify orphan references; compute a stable fingerprint; report unsupported collections. No target writes.
2. **Reference data:** import categories, contacts, warehouses, services, and products. Resolve dependencies before child records. Protect product costs separately.
3. **Draft documents:** import goods/service invoices as drafts only. Validate every customer, product/service, warehouse, date, quantity, amount, discount, tax, and item count. Keep original legacy identifiers in the mapping ledger.
4. **Reconciliation:** compare source and normalized counts/totals per business; detect unmapped rows, duplicate numbers, mismatched totals, and orphan references. Produce a report before any posting.
5. **Dedicated transactional operations:** payments, receipts, cheques, purchases, opening stock, returns, expenses, debts, supplier balances, account transfers, and stock movements require dedicated idempotent RPCs and journal/stock tests. Purchase posting is in 019, goods-sale posting in 020, FIFO warehouse transfer in 021, valued opening stock in 022, and FIFO wastage write-off in 023; returns and remaining lifecycle operations are still pending. They must not be replayed as generic upserts.
6. **Cutover:** retain the legacy source and a recoverable export until the owner explicitly approves a tested cutover. No automatic deletion or destructive replacement.

## Explicitly unsupported until separately designed

Do not import these as normalized financial or inventory facts yet: `pay`, `debt`, `creditors`, `creditorPayments`, `expenses`, `purchases`, `supplierPayments`, `returns`, `wastage`, `stockMoves`, `warehouseStocks`, `transfers`, `accounts`, `moneytransfers`, `opening`, `otherincome`, and cheque lifecycle data. These collections need source-shape audits, account/contact allocation rules, cheque status mapping, opening-balance semantics, and transactional posting RPCs.

## Current implementation status (2026-11-19)

- Migrations 014–015 provide the private business-scoped identity map and read-only preflight. Preflight covers customers, suppliers, products, primitive categories/services, warehouses, fiscal periods, and invoice references; it also reports missing supplier references in legacy purchases. It never writes normalized records or exposes protected payloads.
- Migrations 017–023, 031–034 add dedicated, idempotent transactional operations for customer receipts, supplier payments, expense payments, other income, goods purchases, goods sales with FIFO costing, FIFO warehouse transfers, valued opening stock, wastage, service sales/purchases, cheque lifecycle and reversal, and invoice-linked goods sales returns with FIFO cost restoration. Account transfers are handled by migration 010. Generic sync remains blocked for unsupported financial and stock collections.
- Migrations 024–027 import customer/product references, catalog/warehouse metadata, and goods/service invoice drafts. Migration 029 imports supplier contacts; migration 030 preserves legacy fiscal locks as closed normalized periods. Imported invoices remain drafts and require review/posting through the ordinary normalized posting RPCs.
- Migration 028 provides a read-only count-based reconciliation and cutover gate. It includes mapped source fingerprints, unresolved mappings, deferred financial/other collections, and invoice drafts awaiting review. It does not declare cutover safe while deferred or unresolved rows remain.
- CI applies 34 draft migrations in dependency order (013 follows a test-only license fixture) and runs 36 SQL regression scripts on disposable PostgreSQL 17 with a minimal Auth compatibility shim. P-256 device-proof crypto tests and Edge Function type-check are also included. This does not prove behavior against real Supabase Auth/JWT/Edge Functions or production data.
- No importer has been run against production and no draft migration has been applied to the live Supabase project. Existing license records/activations remain untouched.

## Next implementation gate

The remaining server-side work is deliberately narrower than the original bridge plan:

1. Design returns/refunds around original posted document items, returned-quantity ceilings, customer/supplier ledger effects, and exact FIFO cost restoration. Legacy return rows without an original invoice/item reference must remain in reconciliation until matched; never auto-post them.
2. Complete cheque creation, immutable event history, status transitions and cleared/bounced settlement posting. A status-only change must not masquerade as a cash receipt or supplier payment.
3. Decide whether legacy bank-account metadata, due dates and SMS history need normalized targets. Add importers only after target schema, privacy/retention rules, and ownership semantics are explicit.
4. Expand reconciliation to compare source and normalized counts/totals for every supported collection, report every deferred collection, and produce an owner-reviewed cutover report.
5. Exercise concurrency, role revocation, replay, offline retries and multi-device conflict behavior. Verify the full auth/device/sync flow against a real isolated Supabase environment when one is available.

The release gate remains unchanged: retain the legacy source and a recoverable export; do not cut over, delete, or rewrite source data without a tested recovery plan and the owner's explicit approval.

## First legacy reference import (024)

The first write-phase importer intentionally supports only `cust` and `prod`. It reads the sanitized public payload and never reads `payload_private`; product purchase cost (`buy`) is therefore not imported. The product's legacy `qty` is a balance rather than a movement and is ignored until a separate stock-opening reconciliation is approved. Each imported row is linked to `legacy_normalized_record_map` using a SHA-256 fingerprint. Same-fingerprint reruns are no-ops; changed source payloads are flagged as conflicts rather than silently overwriting user edits. Tombstones are skipped. The RPC requires business administration, contacts-write and catalog-write permissions. No production import has been run.


## Catalog and warehouse reference import (025)

The app sync engine represents `categories` and `services` as primitive strings, normalized on the wire to `{ value: <text> }` with legacy IDs `value:<text>`. The preflight RPC (015) validates this identity format instead of incorrectly requiring an `id` property. Warehouses are object records with stable string IDs generated by the legacy app; these IDs are not UUIDs, so migration 025 maps them to new normalized warehouse UUIDs rather than casting the source ID. Category assignment uses exact label equality only. No legacy warehouse balance is imported.

The legacy `returns` records contain date, customer ID, product ID, warehouse ID, quantity, refund amount and note, but no original invoice or invoice-item ID. The importer must not auto-post these as normalized returns: a later reconciliation step must match them to original posted sale lines and prove returned quantity/value/cost before any financial or stock posting.


## Legacy goods invoice draft import (026)

The app's `inv` collection is imported only after customer, product and optional warehouse references have mapped successfully. Each goods invoice becomes a normalized `goods_sale` document in `draft` status through `create_document_draft`; the importer preserves the legacy invoice number and item description snapshots. It never reads `payload_private`, so item `b` cost values are excluded. It also ignores `bankAccountId` and does not replay the separate `pay` collection. A legacy invoice must be posted through the ordinary normalized goods-sale posting RPC after a user reviews it; draft import creates no stock movement, FIFO allocation, contact-ledger entry, financial transaction or journal. Changed source rows are conflicts and do not overwrite the draft.


## Legacy service invoice draft import (027)

The app's `serviceInv` rows are imported as `service_sale` drafts after the customer and each primitive service-name reference are mapped. Item `cost`, `costTotal`, `costMode`, `bankAccountId` and separate initial `pay` records are not imported by this function. The importer preserves the service description and price/quantity snapshots, fingerprints the sanitized source, and treats source changes as conflicts. A user must review and post the draft through normalized operations; import itself creates no financial transaction, cost snapshot, journal or stock movement.


## Reconciliation/cutover gate (028)

The reconciliation RPC reports only per-collection counts and never exposes source payloads. It detects unmapped records, changed source fingerprints, explicit conflicts, orphaned normalized targets, deleted legacy rows and imported invoice drafts awaiting review. It separately lists the counts of deferred financial/stock collections. The gate is intentionally conservative: any deferred financial/stock row or unreviewed imported draft keeps `safe_to_cutover=false`. It is not a production readiness claim until all supported data has been reconciled and the real Supabase environment has been validated.


## Supplier contacts (029)

Legacy suppliers are separate stable-ID records in `db.suppliers` with name, phone, address and note. Migration 029 imports the safe contact fields as normalized supplier contacts and maps the legacy string ID to the normalized contact UUID. It does not create purchase balances, supplier ledger entries or payments. The preflight additionally checks purchase rows for supplier references that do not resolve to a legacy supplier. The reconciliation report now counts the remaining bank-account, fiscal-period, due-date and SMS-history collections as deferred rather than declaring cutover safe while they remain.


## Fiscal-period lock import (030)

The legacy app stores closed fiscal periods with `id`, `title`, `from`, `to` and `note`. Migration 030 maps each valid non-overlapping range to a normalized `fiscal_periods` row with status `closed`. This preserves the legacy protection against editing transactions in closed periods. The source note is not copied because the normalized fiscal-period schema has no notes field; it remains in the legacy source. The reconciliation gate now counts fiscal rows as a supported mapped collection, not as an unhandled deferred collection.


## Normalized service posting (031)

The normalized model now posts `service_sale` and `service_purchase` drafts through a dedicated transactional RPC. Sales post receivables against service revenue and output tax; service purchases post service expense and recoverable tax against supplier payables. Both create balanced journals and contact-ledger entries in one transaction. Neither creates inventory movements, FIFO layers, item cost snapshots or cash transactions. The legacy service invoice importer (027) still creates drafts only; posting requires normal user review and explicit RPC invocation.
