# Account-bound licensing and multi-device shared-business migration plan

Date: 2026-11-18
Branch: work/factoori-shared-db-integration
Status: architecture/audit draft only — no production changes authorized or performed.

## Decisions captured from product requirements

- A user account may sign in on multiple Android devices and the web app.
- Those sessions must resolve to the same business membership and shared business data.
- Changes and deletions must propagate to other authorized devices after successful synchronization.
- Employees use their own verified accounts and receive access only through explicit membership in a business, with server-enforced permissions.
- A paid perpetual license belongs to the purchasing account/business, not to a handset. A second unrelated account on the same handset must not inherit Premium.
- The business owner may use the same entitlement across their authorized devices. Employees may use business features through membership and permissions; they do not become license owners.
- Existing purchasers and existing device licenses must not lose access during migration.

## Verified current state

### Production Supabase project

Read-only inspection of project `rtlwztotaolbnjdtsjqy` found only these public application tables:
- `app_licenses` (3 rows)
- `factori_license_keys` (11 rows)
- `factori_license_activations` (5 rows)
- `factori_license_nonces` (14 rows)

There are no deployed `profiles`, `businesses`, `business_members`, normalized accounting tables, or sync tables. Production migration history currently contains only:
- `20261113191650_factori_order_license_fulfillment`
- `20261113191746_factori_order_license_idempotent_retry`

Deployed Edge Functions:
- `activate-license` v15, gateway JWT verification disabled
- `admin-license-manager` v5, gateway JWT verification disabled
- `issue-factoori-order-license` v5, gateway JWT verification disabled
- `send-faraz-sms` v11, gateway JWT verification disabled

The deployed license activation function accepts a license key and device public key proof, consumes the license against a device thumbprint, and signs a token containing device identity/permanent status. It does not bind activation to `auth.uid()` or a purchasing account. The Android `license-client.js` validates that token against the handset thumbprint and reads it from native LicenseManager storage; `isLicensed()` has no account/user argument. This explains why changing the signed-in email on the same handset does not remove Premium.

The legacy `public.activate_license(text,text)` RPC is SECURITY DEFINER and executable by anon and authenticated. It is a compatibility-sensitive legacy surface and must not be changed until old-client usage and retirement strategy are established.

A read-only status breakdown of the 11 modern `factori_license_keys` rows found 5 active (only 1 has `payment_verified_at` and an order link), 4 revoked, and 2 unused (both payment-verified/order-linked). The separate legacy `app_licenses` table has 3 unused rows. This means historical ownership cannot safely be inferred from `order_id` for every active license; grandfathering must support proof by the original license key and a controlled support path for exceptional records. No raw license keys or hashes were read.

Security advisor findings currently include:
- RLS enabled with no policies on the four license tables (INFO).
- Legacy `public.activate_license(text,text)` SECURITY DEFINER executable by anon/authenticated (WARN).
- Leaked-password protection disabled (WARN).

### Development branch

The branch already contains substantial, un-deployed shared-business work:
- draft migrations 001–010 for identity, business membership, documents, financial ledger, catalog/inventory, sync, member management, transactional posting, device proof and account transfers;
- client-side account/business selection and business-scoped local database storage;
- a sync engine with per-business checkpoints, operation IDs, conflict handling, tombstones and permission-version resets;
- P-256 device proof client and `prove-sync-device` Edge Function source;
- employee management UI and RPC/Edge Function client calls.

The application health probe expects the shared schema and many RPCs/Edge Functions to exist. Because those objects are absent in production, the app should not be treated as having live multi-device shared-business sync yet.

The current sync write allowlist is intentionally limited to:
`cust`, `suppliers`, `duedates`, `prod`, `services`, `categories`, `inv`, `serviceInv`, `warehouses`, `bankAccounts`, `fiscal`, `smsHistory`.
Financial and inventory posting operations are not generally writable through generic sync; dedicated transactional RPCs are still required.

The draft review documents explicitly record blockers:
- device proof is not deployed;
- no end-to-end Android/web sync runtime validation;
- concurrency, replay, permission revocation and offline recovery need tests;
- legacy local data migration and ID mapping are incomplete;
- invitation delivery/rate limiting and owner recovery/transfer are incomplete;
- paid-plan entitlement enforcement is a placeholder;
- several accounting, payment, purchase, expense, cheque and inventory workflows still need normalized transactional RPCs.

The app-side free limits and draft database quota defaults are now aligned at 3 invoices/day, 5 customers, 5 products, and 2 items/invoice. Migration 004a seeds these values for new and existing draft businesses; regression test 013 asserts the customer, product, invoice-item, and daily-invoice caps. This alignment is still draft-only and is not active in production. Draft 013 ensures a valid perpetual Premium entitlement bypasses server-side Free quota checks; subscription lifecycle and paid-plan entitlements beyond the perpetual license remain out of scope.

The existing isolated PostgreSQL 17 CI validates SQL draft application and regression assertions, but its own README correctly states that it is not a full Supabase/Auth/Edge Function emulator and does not prove production readiness.

## Target ownership model

1. **Auth identity** — Supabase Auth user ID is the immutable identity. Never authorize using user-editable `user_metadata`.
2. **Business tenant** — business data is keyed by `business_id`. One owner account controls the business and its membership lifecycle.
3. **Membership** — an employee's own Auth account receives access only through an active `business_members` row. Every read/write and RPC checks tenant membership and permission on the server.
4. **License entitlement** — a verified purchase is claimed by the authenticated purchasing account and grants a perpetual entitlement to the owner's business. The entitlement is not stored as a device-local source of truth. The owner can use it on their authorized devices; employees inherit only the business entitlement through their membership and permission checks.
5. **Device registry** — devices are registered per user/business and prove possession of a private key. Device proof protects sync endpoints; it does not decide who owns Premium.
6. **Client cache** — local data is a cache/checkpoint for the selected business, never the authority for membership, license ownership, or permissions.

## Proposed account-license migration (design only)

- Preserve existing license keys, activations, signing keys and old-client verification while introducing a separate account/business entitlement path.
- Add a server-owned purchase/claim relation that links a verified order/license to exactly one Auth user and one owner business, with immutable audit history and idempotent claim semantics.
- Claiming must require a valid authenticated session and server-side verification of the purchase/claim credential. Do not accept a client-supplied user ID, email, owner flag, or Premium boolean as proof.
- Add a server RPC/Edge Function to return the caller's effective business entitlements after checking active membership, owner linkage, license state and revocation/expiry rules.
- Move Premium gating from the handset-only LicenseManager token to the authenticated business entitlement result. If offline support is required, use a short-lived signed entitlement cache with explicit expiry and safe behavior when it expires; never treat an indefinitely cached device token as account ownership.
- Existing paid users must be grandfathered through a controlled claim/migration flow. Do not auto-assign historical licenses to whichever account happens to sign in on a device, because that would allow account hijacking of old device entitlements.
- Keep the legacy activation endpoint working for old APKs during a defined compatibility window. Do not revoke or rewrite old activations until account claims and customer support recovery have been validated.

## Account-license implementation slice added on the development branch

Draft migration `013_account_bound_license_entitlements.sql` and regression test `013_account_bound_license_entitlements.sql` now exist. The draft:
- accepts a plaintext purchase key only through an authenticated RPC and hashes it server-side using the same SHA-256/trim convention as the existing activation Edge Function;
- allows a new unused key only when payment verification exists, or a previously activated key when an activation record exists (legacy key-possession claim);
- requires the caller to be the active owner of the selected business;
- makes repeated claims by the same owner/business idempotent and prevents a different account/business from taking the key;
- keeps entitlement history when a license is revoked and permits a replacement purchase to become the new active business entitlement;
- derives Premium server-side from the business owner and non-revoked entitlement; employees receive the business plan through active membership, but cannot claim licenses;
- makes the server-side per-record and daily Free quota functions bypass limits only while the business has a valid Premium entitlement; revocation restores Free enforcement and replacement licenses preserve history;
- stores entitlement rows in the private schema and exposes no direct table access.

`cloud-client.js` now has a `claimLicense(businessId, licenseKey)` RPC wrapper. The cloud readiness probe is being extended to verify that this RPC is deployed. The app now uses the selected business entitlement for Premium gating after an account has been used on that installation; it persists an account-license mode marker so logout does not fall back to a handset token. The license-entry UI routes signed-in users through `claimLicense`, while accounts that have never entered account mode retain the old device-activation path for compatibility. This client integration passed the local sync/static regression workflow, but has not been exercised against a deployed Supabase staging project. Offline entitlement caching, server enforcement for every premium-only operation, legacy `app_licenses` recovery, and old-client compatibility remain open.

CI creates a disposable license-schema fixture matching the existing production table shape; it does not read or modify production license data. The migration and test remain under `supabase/drafts/` and `supabase/tests/`.

## Required work before production

1. Reconcile the full SQL draft sequence, dependencies, grants, RLS policies and RPC signatures against the current Supabase project.
2. Fix the owner-membership invariant and define safe owner transfer/recovery and account deletion/retention.
3. Implement account-bound license claim/entitlement schema and server logic with unique constraints, audit records, payment verification, replay/idempotency protections and legacy grandfathering.
4. Complete normalized transactional RPCs for all financial/inventory actions that must sync; keep unsupported generic writes blocked.
5. Align Free/Pro quota values in app and server and enforce all quotas server-side.
6. Deploy nothing to production until a disposable Supabase staging project has the schema, Auth configuration, Edge Functions, RLS/advisor review and real client integration tests.
7. Run multi-user/multi-device tests: same owner on two devices, unrelated accounts on one device, employee account, revoked employee, lost/replaced device, offline edits, simultaneous edits/deletes, replayed batches, stale permissions, quota races and account logout/switch.
8. Design and rehearse legacy local-data import, business ID mapping, reconciliation and rollback/forward-repair.
9. Prepare a staged rollout and explicit customer migration/support path.
10. Obtain explicit approval before any production migration, Edge Function deployment, license reassignment or PR merge.

## Immediate next implementation slice

Work only on this development branch:
- complete a source-to-production inventory for every table/RPC/Edge Function the current app health probe requires;
- design and test account-license claim tables/functions in isolated PostgreSQL CI, without touching production;
- add regression tests for account isolation and same-account multi-device entitlement semantics;
- reconcile quota policy and document unsupported sync collections;
- continue the sync and auth integration only after those tests pass.

No production schema, production Edge Function, existing license activation, main/release branch, or backup branch was changed as part of this audit.
