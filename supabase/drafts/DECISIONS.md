# Factoori database decisions and test gates

## Must be finalized before production
1. **Costing:** choose weighted average or FIFO. Historical sale profit must use `items[].b` snapshots regardless of the future method.
2. **Currency:** canonical storage candidate is integer IRR. Existing `db.cu` is a mutable display/input setting; it cannot establish the historical unit of every old amount. Migration must stop for ambiguous businesses/records.
3. **Cheque lifecycle:** explicitly map legacy `pending`, `received`, `returned`; distinguish deposited, collected, assigned, cancelled, and returned events.
4. **Numbering:** confirm whether invoice sequences reset each fiscal period and whether goods/service documents have independent sequences.
5. **Retention:** define retention for SMS history, cheque images and audit data.
6. **License claim:** define authenticated claim flow linking an existing license to one business without changing device activation or legacy license semantics.
7. **Service cost:** current handler writes row-level costs and `costMode='row'`; total-cost mode is future compatibility, not an assumption for old records.
8. **Legacy inventory:** `products.qty`, `warehouseStocks`, and `stockMoves` are different evidence sources. Opening inventory must be reconciled and inserted once; do not replay old movements blindly.

## Mandatory test scenarios
- Seller can issue a sale invoice but cannot read product costs, document cost snapshots, margin or profit reports.
- A member cannot read/write another business by changing UUIDs in API requests.
- Revoked/suspended membership immediately loses database access.
- Concurrent invoice numbering never duplicates a number.
- Concurrent sales cannot oversell when negative stock is disabled.
- Allocations cannot exceed the source transaction even under concurrent requests.
- A pending cheque reduces customer receivable according to legacy business semantics but is not cash/bank.
- Cheque collection moves value from cheques receivable to bank without reducing customer debt twice.
- Cheque return restores customer receivable.
- Cheque assignment reduces supplier/creditor payable without inventing cash.
- A posted journal entry cannot be updated/deleted and always balances.
- A correction creates a linked reversal/corrective entry.
- A service invoice's initial receipt is migrated once only.
- A return with no source invoice remains unlinked; no fabricated source relationship.
- Ambiguous legacy currency or warehouse allocation is flagged for review, never guessed.
