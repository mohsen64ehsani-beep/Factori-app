# 004 catalog and inventory foundation — review gates

Status: **DEVELOPMENT DRAFT ONLY — NOT EXECUTED**

Introduces products, categories, services, separate protected product costs, private-permission document item cost snapshots, stock movement ledger, stock transfers, FIFO/weighted cost-layer primitives, and tenant-safe read policies.

## Security and data rules
- Sales users can read products and sale prices but cannot read product purchase costs or historical cost snapshots unless granted \`catalog.cost.read\`.
- Stock movement quantities are visible only to members with \`inventory.read\`.
- All write privileges remain revoked; inventory changes must be made through future validated RPCs.
- Do not place purchase cost or margin in \`products\`, \`stock_movements\`, or other broadly readable payloads.
- \`stock_movements\` is intended as an append-only ledger. Corrections must be compensating movements, not updates/deletes.
- \`inventory_cost_layers\` and allocations preserve cost provenance for FIFO; weighted average requires a separate per-business costing implementation.

## Blocking implementation work
1. Build product/service/category create/update RPCs with normalized name/SKU/barcode validation and concurrency-safe uniqueness.
2. Build stock posting RPCs for purchase, sale, return, wastage, adjustment, and paired warehouse transfer; lock balances/layers.
3. Implement a balance projection or a safe aggregate query. Do not trust a client-maintained stock quantity.
4. Implement weighted-average and FIFO costing explicitly and test historical cost snapshots against current app profit calculations.
5. Add cost snapshot creation during sales posting and preserve legacy item \`b\` purchase-cost snapshots for historical profit.
6. Validate that document item product/service IDs belong to the same business and match item/document types.
7. Ensure inventory quantity and cost allocations cannot go negative under concurrent sales.
8. Decide handling for negative stock and per-warehouse vs business-wide costing.
9. Add idempotency, version conflicts, fiscal period checks and reversal logic to every stock mutation RPC.
10. Add tests for tenant isolation, cost privacy, concurrent stock depletion, transfers, returns, FIFO layer consumption and weighted average.

This is a schema foundation, not a functioning inventory engine. Apply only in isolated staging after migrations 001-003 pass their tests.
