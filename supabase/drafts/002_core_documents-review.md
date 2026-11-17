# 002 core documents — review gates

Status: **DEVELOPMENT DRAFT ONLY — NOT EXECUTED**

This draft supplies tenant-scoped contacts, warehouses, fiscal periods, document headers/items, and a server-validated draft-creation RPC. It deliberately does not post accounting entries, update inventory, process payments, or permit direct client edits to documents.

## Blocking review items
1. Validate exact numeric bounds and rounding for the app's Rial/Toman convention; this draft uses integer currency amounts and must not be deployed until canonical currency storage is finalized.
2. Add source-item reference validation once normalized products/services are migrated; UUID snapshots are currently optional and are not FK-bound.
3. Add document edit/delete draft RPCs with optimistic version checks; no direct write grant is provided.
4. The RPC now checks fiscal-period date/status and contact role; add tests for closed periods, out-of-range dates, inactive contacts and role mismatch.
5. Confirm tax calculation and discount allocation against the current app for multi-rate invoices, rounding, header discount, and zero-value lines.
6. Idempotency stores a request fingerprint and rejects reuse with a changed payload; concurrency-test identical and conflicting simultaneous requests.
7. Item-type/document-type compatibility is checked; add negative tests for goods/service mismatches.
8. Ensure contact/warehouse/fiscal period composite foreign keys and RLS behavior are tested with cross-business IDs.
9. Add a safe posting RPC that atomically creates journal entries, stock movements, contact ledger entries, and status transition. Until then, all rows remain drafts.
10. Reconcile the exact function signature against the deployed client bundle before enabling the shared account UI.

## Explicit non-goals
- No automatic accounting or stock ledger is created by this draft.
- No paid/free quota is enforced here.
- No legacy data import or local-to-cloud sync is performed.
- No existing license table/function is altered.

Apply only in a disposable staging project after migration 001 is reviewed and tested. Never run on production without the complete migration package and explicit approval.
