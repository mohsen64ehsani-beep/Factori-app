# Legacy db:v2 to normalized accounting bridge

Status: design checkpoint only — no migration, production data, or live Supabase project is changed by this document.

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

The app has separate `services` and `serviceInv` collections. Service invoice editor rows use `desc`, `qty`, `price`, and `cost`; service invoice headers use `cid`, `no`, `dt`, `bankAccountId`, `discount`, and cost-mode fields. The complete persisted shape and service catalog row shape still require a focused source audit before an importer is written.

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
5. **Dedicated transactional operations:** payments, receipts, cheques, purchases, returns, expenses, debts, supplier balances, account transfers, and stock movements require dedicated idempotent RPCs and journal/stock tests. They must not be replayed as generic upserts.
6. **Cutover:** retain the legacy source and a recoverable export until the owner explicitly approves a tested cutover. No automatic deletion or destructive replacement.

## Explicitly unsupported until separately designed

Do not import these as normalized financial or inventory facts yet: `pay`, `debt`, `creditors`, `creditorPayments`, `expenses`, `purchases`, `supplierPayments`, `returns`, `wastage`, `stockMoves`, `warehouseStocks`, `transfers`, `accounts`, `moneytransfers`, `opening`, `otherincome`, and cheque lifecycle data. These collections need source-shape audits, account/contact allocation rules, cheque status mapping, opening-balance semantics, and transactional posting RPCs.

## Next implementation gate

Before writing migration 014 or importer RPCs:

- audit the complete persisted shapes and edit/delete flows for the supported legacy collections;
- inspect the full normalized table constraints, RLS policies, and existing draft-creation RPC signatures;
- specify whether import is an owner-only one-time operation or a repeatable reconciliation;
- add tests for idempotency, cross-business isolation, permission denial, sensitive cost separation, orphan references, and exact totals;
- test against isolated PostgreSQL and a real Supabase test environment when one is available.

This document deliberately does not claim that the bridge is implemented. It records the verified data model and the safe order for implementing it.
