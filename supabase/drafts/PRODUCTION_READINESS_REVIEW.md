# Factoori shared database — production readiness review

Date: 2026-11-18
Branch: work/factoori-shared-db-integration

## Current validation

- Draft migrations 001–007 apply in dependency order on disposable PostgreSQL 17.
- Regression checks 001–009 pass in GitHub Actions run 44238138762.
- Security-surface test 008 checks RLS on public tables, denies direct anon table privileges, verifies fixed search_path on SECURITY DEFINER routines, and checks private SECURITY DEFINER routines are not executable by anon.
- Sensitive-payload test 009 verifies recursive extraction/stripping and round-trip restoration for representative nested invoice data.
- These checks are not a production security certification and do not exercise the full authenticated multi-user workflow. The latest local sync CI run 44312629394 reports 47 tests passed, 0 failed.

## Production blockers — do not apply to the live Supabase project

1. **Device key possession is not established.** `sync_devices.device_public_key` is nullable JSON. `private.register_sync_device` accepts it without validating a supported key format or a proof-of-possession challenge. The push/pull functions authorize by Supabase user membership and device row ownership, not by a cryptographic device signature. Define key algorithms, canonical request signing, nonce/challenge lifecycle, replay prevention, rotation/revocation, and Android/Web key storage before claiming device-bound security.
2. **Financial and inventory writes are intentionally blocked in generic sync.** `can_sync_collection` denies writes for payments, purchases, returns, expenses, stock movements, transfers, opening balances, etc. Dedicated normalized, transactional RPCs must be designed and tested before existing app functionality can safely sync.
3. **No end-to-end client sync implementation has been validated.** The current checks validate database objects and selected function definitions; they do not prove that the Android client correctly registers devices, pushes idempotent batches, handles conflicts, pulls tombstones, resets after permission changes, or resumes after offline/retry conditions.
4. **Concurrency and adversarial behavior need runtime tests.** Exercise simultaneous devices, duplicate operation IDs with same/different payloads, stale versions, simultaneous quota consumption, invitation acceptance races, role revocation during sync, and cursor pagination with interleaved unreadable collections.
5. **Legacy license surface remains separate.** The existing public `activate_license(text,text)` SECURITY DEFINER RPC is a legacy path with broader anon/authenticated execute grants. Do not alter it until old-client compatibility and migration/retirement strategy are established.
6. **Invitation delivery and abuse controls need trusted implementation.** Token generation/hash, verified-email checks, email delivery, rate limits, duplicate invitation handling, and concurrent acceptance require Edge Function and runtime validation.
7. **Migration and data conversion are not complete.** No legacy localStorage data has been migrated; ID mapping, currency unit semantics, historical balances, cheque attachments, stock layers, and accounting opening balances require deterministic migration design and reconciliation tests.

## Release gate

Do not run these draft migrations on the production Supabase project. Do not start app/site shared-data integration until blockers above are resolved, an isolated Supabase staging environment is available, migration rollback/forward-repair procedures are rehearsed, and the user explicitly approves the final reviewed SQL package.
