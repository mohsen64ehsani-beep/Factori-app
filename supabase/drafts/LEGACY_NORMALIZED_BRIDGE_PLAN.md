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

## Current implementation status (2026-11-18)

- Migration 014 now creates the private business-scoped legacy identity map. It stores a source fingerprint and target identity, not the source payload.
- Migration 015 now adds `preview_legacy_normalization(uuid)`, a read-only owner/admin audit RPC. It counts supported collection rows, tombstones, malformed payload objects, missing/mismatched payload IDs, and orphan customer/product references in goods invoices. It reports deferred financial collections and never writes normalized records.
- CI runs the current ordered draft migrations and SQL regression suite on disposable PostgreSQL 17 with a minimal Auth compatibility shim. The preflight test includes runtime fixtures for orphan detection, read-only behavior, and tenant isolation. This is not a complete Supabase Auth/JWT/Edge Functions environment.
- The active app source audit confirms the customer, product, goods-invoice, service-catalog, and service-invoice shapes described above. Service costs and invoice cost fields are sensitive. Initial service-invoice receipts are separate `pay` records.
- `warehouses`, categories, product category IDs, complete service catalog reconciliation, and every edit/delete/tombstone path still need focused audit before importing those records.

## Next implementation gate

The next work is completion of normalized transactional returns and remaining cheque/account lifecycle operations, followed by expanding the importer from customer/product reference data to categories, warehouses, services and draft documents. Before any import RPC is added:

- finish the source audit for warehouses, category references, product edits, service costs, invoice edits/deletes, and all related tombstone behavior;
- inspect the complete normalized table constraints, RLS policies, and transactional RPC signatures for contacts, products, services, warehouses, and draft documents;
- choose a repeatable owner-only import/reconciliation contract with generation IDs, fingerprints, conflict handling, and no destructive source changes;
- add dry-run and write-phase tests for idempotency, cross-business isolation, permission denial, sensitive cost separation, orphan references, exact totals, and retry behavior;
- test against isolated PostgreSQL and a real Supabase test environment when one is available.

Migration 024 imports customers and products through an owner-authorized, fingerprinted RPC, excluding cost and quantity. Migration 025 imports primitive category/service names and warehouse metadata and links exact product category labels; it does not import warehouse quantities or stock movements. Migration 026 imports goods invoices as normalized drafts only; it does not post stock, receivables, journals or payments, and it excludes protected legacy cost snapshots. Service invoices and financial records remain deferred. The bridge remains incomplete: service-invoice import, full reconciliation, returns matching, and transactional financial/stock conversion remain outstanding.


## First legacy reference import (024)

The first write-phase importer intentionally supports only `cust` and `prod`. It reads the sanitized public payload and never reads `payload_private`; product purchase cost (`buy`) is therefore not imported. The product's legacy `qty` is a balance rather than a movement and is ignored until a separate stock-opening reconciliation is approved. Each imported row is linked to `legacy_normalized_record_map` using a SHA-256 fingerprint. Same-fingerprint reruns are no-ops; changed source payloads are flagged as conflicts rather than silently overwriting user edits. Tombstones are skipped. The RPC requires business administration, contacts-write and catalog-write permissions. No production import has been run.


## Catalog and warehouse reference import (025)

The app sync engine represents `categories` and `services` as primitive strings, normalized on the wire to `{ value: <text> }` with legacy IDs `value:<text>`. The preflight RPC (015) validates this identity format instead of incorrectly requiring an `id` property. Warehouses are object records with stable string IDs generated by the legacy app; these IDs are not UUIDs, so migration 025 maps them to new normalized warehouse UUIDs rather than casting the source ID. Category assignment uses exact label equality only. No legacy warehouse balance is imported.

The legacy `returns` records contain date, customer ID, product ID, warehouse ID, quantity, refund amount and note, but no original invoice or invoice-item ID. The importer must not auto-post these as normalized returns: a later reconciliation step must match them to original posted sale lines and prove returned quantity/value/cost before any financial or stock posting.


## Legacy goods invoice draft import (026)

The app's `inv` collection is imported only after customer, product and optional warehouse references have mapped successfully. Each goods invoice becomes a normalized `goods_sale` document in `draft` status through `create_document_draft`; the importer preserves the legacy invoice number and item description snapshots. It never reads `payload_private`, so item `b` cost values are excluded. It also ignores `bankAccountId` and does not replay the separate `pay` collection. A legacy invoice must be posted through the ordinary normalized goods-sale posting RPC after a user reviews it; draft import creates no stock movement, FIFO allocation, contact-ledger entry, financial transaction or journal. Changed source rows are conflicts and do not overwrite the draft.
