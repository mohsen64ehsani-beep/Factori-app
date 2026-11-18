# Factoori shared database — production readiness review

Date: 2026-11-18
Branch: work/factoori-shared-db-integration

## Current implementation update (2026-11-19)

The development branch has advanced well beyond the original 001–007 audit snapshot. It now contains 32 draft migrations (including 013, which CI applies after a test-only legacy license-schema fixture) and 34 SQL regression scripts. The latest completed database CI run applies the complete ordered draft set on disposable PostgreSQL 17 and passes the SQL regression suite plus P-256 device-proof tests. The CI environment remains a minimal Supabase Auth compatibility shim, not a full Supabase emulator.

Implemented server-side slices on the development branch now include:
- tenant identity, business membership/permissions, document drafts, financial ledger, catalog and inventory schema;
- guarded generic compatibility sync with financial and stock collections still blocked from arbitrary writes;
- P-256 device-proof function source and replay tests (not deployed);
- account-bound license entitlement draft (not deployed and not migrated into production);
- idempotent customer receipts, supplier payments, expense payments and other income;
- goods purchase posting, goods sale posting with FIFO consumption, FIFO warehouse transfers, valued inventory opening and wastage posting;
- service sales and service purchases with balanced journals and contact ledgers;
- legacy customer/product, supplier, catalog/service/warehouse, goods/service invoice draft, and closed fiscal-period import slices;
- read-only legacy preflight and reconciliation/cutover gates.

These are development drafts only. No draft migration or new RPC has been applied to the live Supabase project. No legacy data import has been executed against production. Existing license activations and the production license tables/functions remain unchanged.

## Current validation

- Draft migrations 001–007 apply in dependency order on disposable PostgreSQL 17.
- Regression checks 001–009 pass in GitHub Actions run 44238138762.
- Security-surface test 008 checks RLS on public tables, denies direct anon table privileges, verifies fixed search_path on SECURITY DEFINER routines, and checks private SECURITY DEFINER routines are not executable by anon.
- Sensitive-payload test 009 verifies recursive extraction/stripping and round-trip restoration for representative nested invoice data.
- These checks are not a production security certification and do not exercise the full authenticated multi-user workflow. The latest local sync CI run 44312629394 reports 47 tests passed, 0 failed.

## Production blockers — do not apply to the live Supabase project

1. **Device proof is implemented in drafts but not operationally verified.** The branch includes P-256 challenge-response, single-use nonce/replay rejection and Edge Function type/crypto tests. The Edge Function and supporting migrations have not been deployed to Supabase, and Android/Web end-to-end key storage, challenge completion, rotation/revocation and sync enforcement have not been tested against real Supabase Auth.
2. **Some financial/inventory operations remain intentionally blocked in generic sync.** Dedicated idempotent RPCs now exist for receipts, supplier payments, expenses, other income, goods purchases/sales, service sales/purchases, account transfers, warehouse transfers, opening stock and wastage. Returns, refunds, cleared-cheque reversal now has a separate audited reversal RPC. Sales/purchase returns and refunds tied to original invoice items, partial settlements, bank fees and full legacy financial conversion still require dedicated reviewed RPCs. Keep those collections blocked until their transactional paths are tested.
3. **No end-to-end client sync implementation has been validated.** The current checks validate database objects and selected function definitions; they do not prove that the Android client correctly registers devices, pushes idempotent batches, handles conflicts, pulls tombstones, resets after permission changes, or resumes after offline/retry conditions.
4. **Concurrency and adversarial behavior need runtime tests.** Exercise simultaneous devices, duplicate operation IDs with same/different payloads, stale versions, simultaneous quota consumption, invitation acceptance races, role revocation during sync, and cursor pagination with interleaved unreadable collections.
5. **Legacy license surface remains separate.** The existing public `activate_license(text,text)` SECURITY DEFINER RPC is a legacy path with broader anon/authenticated execute grants. Do not alter it until old-client compatibility and migration/retirement strategy are established.
6. **Invitation delivery and abuse controls need trusted implementation.** Token generation/hash, verified-email checks, email delivery, rate limits, duplicate invitation handling, and concurrent acceptance require Edge Function and runtime validation.
7. **Migration and data conversion are not complete.** The branch has fingerprinted importers for customer/product/supplier references, categories/services/warehouses, goods/service invoice drafts and closed fiscal periods, plus read-only preflight/reconciliation. It intentionally does not import or post historical payments, returns, cheques, bank accounts, due dates, SMS history, stock quantities or opening financial balances. Full currency-unit reconciliation, source-to-target totals, returns matching, cheque attachments and financial/stock cutover still require separate design and tests.

## Release gate

Do not run these draft migrations on the production Supabase project. Do not start app/site shared-data integration until blockers above are resolved, an isolated Supabase staging environment is available, migration rollback/forward-repair procedures are rehearsed, and the user explicitly approves the final reviewed SQL package.


## Remaining stage-one backend work

The current branch is a substantial server-side foundation, not a production-ready shared database. The next backend gates are:
1. define and test return/refund matching against original posted document items and FIFO cost allocations;
2. complete cheque creation, lifecycle transitions and cleared/bounced settlement posting with immutable event history;
3. decide/import bank-account metadata and due-date/SMS history only where a normalized target and privacy/retention policy exist;
4. complete reconciliation for all imported and intentionally deferred collections and produce a per-business cutover report;
5. exercise concurrency, real Supabase Auth/JWT, Edge Functions, RLS and Android/Web end-to-end sync in an isolated Supabase environment when one is available.

No production deployment, production data migration, live license modification, main/release merge, or website publication is authorized by this review.
