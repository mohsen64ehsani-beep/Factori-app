# Transactional RPC contracts

> These are API contracts, not claims that every function has already been implemented. Only `create_business`, `allocate_payment`, and `post_journal_entry` have draft SQL bodies in `005_rls_grants_validation.sql`. The remaining routines are implementation gates before production.

All public RPC wrappers must be `SECURITY INVOKER`, revoke default PUBLIC/anon execution, and delegate to private, narrowly-scoped routines. Incoming customer receipts use `payments.receive.create`; outgoing payments use `payments.pay.create`; generic `payments.create` is reserved for trusted finance workflows. Internal `private.assert_feature_limit` and `private.consume_feature_quota` helpers are not executable by client roles; they must be called inside the relevant create/post RPC so quota and business data commit or roll back together. Private SECURITY DEFINER routines must use `SET search_path = ''`, fully-qualified names, `auth.uid()`, explicit business membership/permission checks, and one database transaction. Never expose service_role credentials to app or website clients.

| RPC | Input | Output | Required atomic behavior |
|---|---|---|---|
| `create_business` | name | business UUID | Create profile if needed, business, owner membership and default settings/roles. Draft body exists. |
| `invite_business_member` | business, email/phone, role | invitation id + one-time raw token | Store only token hash in private invitations; require members.manage; rate-limit and expire. |
| `accept_business_invitation` | one-time token | membership id | Hash token, lock invitation, check expiry/revocation, create membership, consume invitation. |
| `update_member_role` | business, member, role | updated member | Require members.manage; never remove/demote final owner; audit change. |
| `set_member_permission_override` | business, member, permission, allow/deny | override id | Require members.manage; validate permission catalog; audit. |
| `create_document_draft` | business, type, header, items, idempotency key | document id + number | Lock sequence, allocate number and create header/items in same transaction; validate fiscal period and contact/warehouse; snapshot description, price, tax and cost; enforce customer/product/item limits; consume the daily invoice quota in the same transaction for sale/service-sale documents. The business-local day is derived server-side from `business_settings.timezone`. |
| `update_document_draft` | business, document id, expected version, patch | new version | Draft-only, optimistic concurrency; reject posted/voided; validate all child IDs belong to same business. |
| `post_document` | business, document id, expected version | posted document id + journal id | Lock document, stock rows and relevant accounts; recompute totals server-side; check stock; create financial transaction/allocations and journal lines; create stock movements/cost allocations; commit all or none. |
| `reverse_document` | business, source document, reason, idempotency key | reversal document id | Create linked reversal; reverse finance, stock and journal effects atomically; never edit source. |
| `record_financial_transaction` | business, type, contact, account, amount, method, date, idempotency key | transaction id | Lock account/contact ledger; validate permissions and currency; create journal entry; cheque methods create cheque record, not cash movement. |
| `transfer_funds` | business, source/destination financial accounts, amount, date, idempotency key | account transfer id | Lock both accounts in stable order; create paired transfer_in/transfer_out transactions and balanced journal lines; no P&L effect. |
| `allocate_payment` | business, transaction, document, amount | allocation id | Draft body exists; lock transaction/document, enforce transaction and document remaining balances and currency equality. Sales users may allocate only customer receipts to sale/service-sale documents; supplier payments require the separate outgoing-payment permission. |
| `reverse_transaction_allocation` | business, allocation id, amount, reason | reversal id | Lock source transaction/allocation; enforce unreversed remainder; append reversal record and update receivable/payable journal effect. |
| `change_cheque_status` | business, cheque, target status, event date, note | event id | Lock cheque; validate transition graph; append event; post corresponding journal/account effect exactly once. |
| `assign_received_cheque` | business, source cheque, creditor contact, amount | assignment id | Lock cheque and creditor balance; ensure available cheque amount; reduce payable without creating cash; append cheque event. |
| `record_stock_movement` | business, product, warehouse, type, quantity, source, idempotency key | movement id | Lock product/warehouse balance; enforce negative-stock setting; calculate cost using selected method; append movement + private cost + balance projection in one transaction. |
| `transfer_stock` | business, from/to warehouses, item list, idempotency key | transfer id | Lock both balances in stable order; create transfer + paired movements and private cost allocations atomically; no P&L effect. |
| `post_journal_entry` | business, entry id | void | Draft body exists; manual journal posting requires `accounting.journal.post`; lock entry/period, validate >=2 lines and debit=credit, enforce open period, then post. System-generated journals from `post_document` must use a separate private posting helper so a permitted salesperson can post an invoice without gaining manual ledger-posting rights. |
| `reverse_journal_entry` | business, entry id, reason | reversal entry id | Create exact opposite lines and link `reversal_of`; original remains immutable. |
| `get_business_entitlements` | business | effective feature map | Verify active membership; resolve current plan, lifetime license and active overrides by `priority`, validity window and latest effective timestamp. A read-only draft RPC is included. |
| `create_or_update_contact` | business, contact fields, idempotency key | contact id | Require contacts.write; enforce customer-count limit under a per-business transaction lock. |
| `create_or_update_product` | business, product fields, idempotency key | product id | Require catalog.write; enforce product-count limit under a per-business transaction lock. |
| `get_contact_balance` | business, contact, as-of date | receivable/payable summary | Return only permitted aggregate balances; do not expose full journal lines or confidential cost data to sales users. |
| `get_profit_report` | business, date range, filters | aggregate profit report | Require reports.profit.read; read private cost snapshots and return aggregates only. |
| `claim_license_to_business` | business, raw license key | linked license id + entitlement result | Authenticated user must be owner; hash key and check existing license tables server-side; enforce one business per license; do not alter device activation JWT. |
| `sync_push` | business, device, operation batch | per-operation applied/conflict/rejected | Idempotent operation IDs; version checks; call domain RPCs; posted finance never last-write-wins. |
| `sync_pull` | business, device, cursor | ordered changes + next cursor | Verify membership and device; permission-filter sensitive fields; stable pagination; never leak private cost rows. |
| `stage_legacy_import` | business, source schema, raw db:v2 JSON, batch key | batch id + validation report | Preserve raw payload; map IDs; detect currency/warehouse ambiguity; no duplicate imports. |
| `commit_legacy_import` | business, batch id | reconciliation report | Owner-only, only after validation; import each collection idempotently; create opening inventory once; preserve legacy links and unknown records. |

## Accounting event rules
- Sale invoice: Dr receivable/cash as appropriate; Cr sales; Cr tax payable; separate Dr COGS / Cr inventory.
- Service invoice: Dr receivable/cash; Cr service revenue; recognize service costs using row-level cost snapshots. Legacy handler writes `costMode='row'`; do not invent total costs.
- Purchase: Dr inventory; Cr supplier payable/cash. A partial payment is a separate linked financial transaction.
- Supplier payment: Dr payable; Cr cash/bank.
- Expense: Dr expense; Cr cash/payable.
- Wastage: Dr wastage loss; Cr inventory using cost snapshot, not today's product purchase price.
- Incoming cheque pending: Dr cheques receivable; Cr customer receivable. It is not cash.
- Cheque collection: Dr bank; Cr cheques receivable; do not reduce customer receivable again.
- Cheque return: reverse collection/settlement and restore customer receivable.
- Cheque assignment: reduce payable and transfer cheque claim; never post cash.
- Account transfer: Dr destination account / Cr source account; no income or expense.
- Sales return: reverse receivable/revenue/tax and restore inventory at historical return cost.
- Supplier return: reverse payable and inventory value.
