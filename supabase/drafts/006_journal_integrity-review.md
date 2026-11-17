# 006 journal integrity — review gates

Status: **DEVELOPMENT DRAFT ONLY — NOT EXECUTED**

This migration adds database-level protections for double-entry journal records:
- posted/reversed journal headers cannot be updated;
- journal lines cannot be changed after posting;
- deferred checks require at least two lines and equal non-zero debit/credit totals;
- posting to inactive or non-posting chart accounts is rejected;
- a posted journal entry cannot belong to a closed or missing fiscal period;
- only one reversal entry may reference a source journal.

## Before production
1. Test trigger behavior for INSERT/UPDATE/DELETE in one transaction, including a journal header posted before lines are inserted.
2. Add a dedicated RPC to post entries; validate permissions, source idempotency, date/period, account class and source-document reconciliation.
3. Add a dedicated reversal RPC that creates exact opposite lines and links the reversal; do not update the source journal.
4. Decide whether the source journal status should remain \`posted\` while a reversal exists; current schema permits a new reversal without mutating the original.
5. Test concurrency and deadlock behavior. The line guard locks the parent journal row.
6. Verify constraint triggers are supported and behave as expected in the target Supabase PostgreSQL version.

No posting RPC or write grant is introduced by this migration. It must be tested in disposable staging.
