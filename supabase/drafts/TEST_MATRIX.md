# Database integration and security test matrix

Run these tests only against a disposable local Supabase stack or isolated database branch populated with synthetic accounts. Never run fixture mutations against the Factoori production project.

## Identity and tenant isolation
- [ ] New Auth user can create a business through `public.create_business`.
- [ ] Creation creates exactly one active owner membership and default settings.
- [ ] Business A member cannot SELECT, INSERT, UPDATE or DELETE Business B rows, including by guessing UUIDs.
- [ ] Suspended business and suspended/removed membership lose access immediately.
- [ ] User can belong to two businesses and switching active business changes every query scope.
- [ ] Invitation token is stored only as a hash in the private schema; expired/revoked tokens cannot be accepted.
- [ ] Last active owner cannot be removed or demoted; ownership transfer is audited.
- [ ] User cannot update own role, permission override, business owner, subscription or entitlement directly.
- [ ] User device preferences reject biometric/fingerprint keys and are scoped to the same authenticated user and device.

## Permission matrix
- [ ] Owner: all operational permissions.
- [ ] Admin: operational management, but no implicit ownership transfer or protected billing operation.
- [ ] Accountant: finance, costs, ledger and profit reports.
- [ ] Sales: create/post sales, record customer receipts and read basic customer/product/inventory data; cannot read purchases, expenses, purchase costs, document cost snapshots, journal lines or profit reports.
- [ ] Sales role cannot create supplier payments, refunds, account transfers or cheque assignments.
- [ ] Viewer: read-only permitted operational summaries.
- [ ] Explicit deny override takes precedence over role allow.
- [ ] No role or override can cross business_id boundaries.

## Document lifecycle
- [ ] Draft can be edited and deleted only through authorized RPC.
- [ ] Posted document and its items reject UPDATE/DELETE.
- [ ] Reversal creates a new linked document and leaves source unchanged.
- [ ] Concurrent number requests never duplicate a number; a failed create may leave a harmless gap.
- [ ] Document totals, discounts and taxes are recomputed server-side, not trusted from client payload.
- [ ] Cross-business contact/product/service/warehouse references fail composite FK validation.
- [ ] Free-text lines preserve description snapshots.

## Financial transactions and cheques
- [ ] Daily invoice quota is consumed atomically with invoice creation; retrying the same idempotency key does not consume quota twice.
- [ ] Entitlement priority lets an active paid/lifetime entitlement override the free-plan limit.
- [ ] Customer/product/item limits are checked server-side under concurrent creates.
- [ ] Idempotent retry with same operation key returns same transaction.
- [ ] Allocation total minus allocation reversals never exceeds source transaction amount under concurrent requests.
- [ ] Partial payment and unallocated receipt remain supported.
- [ ] Pending received cheque reduces receivable only according to approved business rule and never increases cash/bank.
- [ ] Collection moves cheque receivable to bank exactly once.
- [ ] Return reverses settlement and restores receivable.
- [ ] Assignment to creditor reduces payable without recording cash receipt/payment.
- [ ] Issued cheque is tracked separately from received cheque.
- [ ] Cheque status transitions outside the allowed transition graph are rejected.
- [ ] Account transfer creates equal/opposite account effects and no income/expense.

## Inventory and costing
- [ ] Concurrent sales lock stock balance and prevent negative stock when disabled.
- [ ] Transfer creates paired movements atomically and has zero P&L effect.
- [ ] Reversal appends opposite movement; original movement cannot be edited/deleted.
- [ ] Weighted-average method produces deterministic costs under concurrent purchase/sale.
- [ ] FIFO consumes cost layers in order and cannot allocate more than remaining quantity.
- [ ] Cost tables and inventory value projections are inaccessible to sales role.
- [ ] Wastage uses stored historical cost, never current product purchase price.
- [ ] Opening stock is inserted once and reconciled against legacy warehouseStocks/products.qty.
- [ ] Unknown legacy warehouse allocation is flagged, not guessed.

## Double-entry accounting
- [ ] Every posted journal entry has at least two lines and debit equals credit.
- [ ] Closed fiscal period rejects posting.
- [ ] Posted journal entries and lines are immutable.
- [ ] Reversal creates exact opposite lines and links original entry.
- [ ] Sale, service sale, purchase, supplier payment, expense, wastage, returns, cheque lifecycle and account transfer generate correct entries.
- [ ] Customer/supplier balance views are based on posted ledger entries and opening balances.
- [ ] Basic contact balance RPC does not reveal journal details or cost snapshots to sales users.

## Legacy migration
- [ ] Export of db:v2 is immutable and versioned.
- [ ] Every source collection is counted and raw payload preserved.
- [ ] IDs map through legacy_id_map; re-import is idempotent.
- [ ] service_invoice initial receipt is imported once, not regenerated.
- [ ] Old payments without invoice links remain unallocated; no fabricated invoice is created.
- [ ] Currency unit is verified per business/history before conversion; ambiguous values remain needs_review.
- [ ] Historical item cost uses sales item snapshot `b`.
- [ ] Returns use `unitCostAtReturn`; absent snapshots are flagged uncertain.
- [ ] Stock movements are not blindly replayed when current balances already include them.
- [ ] Customer balances, creditor balances, cheques, account balances, inventory and historical profit reconcile within defined tolerances.

## Storage, API exposure and observability
- [ ] Cheque images are in a private bucket and only authorized signed URLs can be issued.
- [ ] API keys and service_role secrets never reach Android/web clients.
- [ ] New public schema tables are explicitly exposed only when required; grants and RLS are reviewed together.
- [ ] No anonymous grants exist on business data.
- [ ] Security Advisor has no unexpected findings; every remaining warning is documented.
- [ ] Logs do not contain raw license keys, invitation tokens, SMS API keys or full cheque/account data.
