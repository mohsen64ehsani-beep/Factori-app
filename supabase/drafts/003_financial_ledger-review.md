# 003 financial ledger primitives — review gates

Status: **DEVELOPMENT DRAFT ONLY — NOT EXECUTED**

Adds tenant-scoped financial accounts, money transactions, transaction-to-document allocations, cheque records and immutable event history, chart of accounts, journal header/lines, and contact ledger entries.

## Deliberate safety boundaries
- No direct client writes are granted.
- No payment, cheque-status, journal-posting, refund, transfer, or reversal RPC is implemented here.
- No row is automatically treated as a balanced journal merely because a transaction row exists.
- Cheque images are represented by a private Storage object path; do not upload Base64 into table rows.
- Financial amounts are integer currency units; confirm the canonical IRR/toman scale before deployment.
- Existing legacy cheque and receipt statuses must be mapped by a reviewed state-transition table, not copied blindly.

## Blocking implementation work
1. Add RPCs for receipt/payment creation, allocation, account transfers, cheque status transitions, cheque assignment to creditors, and refunds. Each must lock affected rows and enforce remaining balances.
2. Add journal posting RPC with balanced debit/credit validation, account-class validation, fiscal-period locking, idempotency, and append-only posted entries. Posted journals must be immutable; corrections use reversal entries.
3. Add deferred/transaction-level balance checks for journal entries and enforce at least two lines for every posted entry.
4. Add event/state transition validation for cheques; direct UPDATE remains ungranted. A cheque assignment must not double-spend a received cheque.
5. Add aggregate guards so allocations cannot exceed transaction amount or document outstanding amount, including concurrent allocation attempts.
6. Define opening-balance sign semantics and currency normalization for existing \`accounts\`, \`bankAccounts\`, \`opening\`, \`pay\`, \`creditorPayments\`, and supplier payment data.
7. Add a unique, explicit source mapping for all migrated ledger rows; do not synthesize missing invoice links for old receipts or returns.
8. Verify sales and purchase return semantics, pending cheque effect on customer balances, bounced cheque reversals, and assigned cheque creditor settlement.
9. Add private cheque-image bucket, object ownership policies, content limits and signed access; no public bucket.
10. Add tests for tenant isolation, role matrix, balanced journals, allocation races, cheque lifecycle, reversal integrity, and historical balance reconciliation.

This migration is a schema foundation only, not a complete accounting engine. Apply only in isolated staging after 001 and 002 pass all tests.
