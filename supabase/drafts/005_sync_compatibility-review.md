# Review: 005 compatibility sync draft

Status: **NOT APPROVED FOR PRODUCTION / NOT EXECUTED**

This SQL is retained only as a development draft. It is not a complete accounting database migration and must not be applied to the live Supabase project.

## Required predecessor schema (not yet present in the repository migration history)

The draft assumes all of the following already exist with compatible columns, keys, and constraints:

- `public.profiles(id)`
- `public.businesses(id)`
- `public.business_members`
- `public.permission_catalog`
- `public.business_settings(business_id, timezone)`
- `public.sync_devices` including `business_id,user_id,device_name,platform,device_public_key,status,last_seen_at`
- `public.sync_cursors` including `business_id,device_id,last_revision,last_synced_at`
- `public.sync_operations` including `business_id,device_id,operation_id,operation_type,record_type,record_id,base_version,result_version,status,result_payload,created_at`
- `public.record_revisions` including `business_id,record_type,record_id,revision,changed_by,change_type,change_payload`
- Private authorization/entitlement functions: `private.is_business_member(uuid)`, `private.has_business_permission(uuid,text)`, `private.assert_feature_limit(uuid,text,integer)`, and `private.consume_feature_quota(uuid,text,date,uuid)`.

The repository currently has no committed predecessor migration defining this schema. The live project inspection previously found only the four license tables; therefore these dependencies cannot be assumed to exist in production.

## Blocking correctness and security work

1. **No normalized accounting effects.** This transport stores legacy collection payloads as JSON. It does not atomically post journal entries, update inventory ledgers, allocate payments, or enforce cheque lifecycle rules. It cannot be presented as the final shared accounting database.
2. **Posted-state trust.** The generic upsert path currently accepts client-supplied payload status values. Before any production use, restrict this compatibility path to safe draft/non-posting data and route posting, payments, stock, and cheque transitions through validated database RPCs.
3. **Permission catalog alignment.** Collection mapping contains permission codes that must be checked against the actual seeded catalog, including `payments.receive.create`, `payments.pay.create`, `payments.create`, `invoice.settings.read`, `settings.read`, and `accounting.journal.post`. Unknown codes must not be silently treated as valid permissions.
4. **Idempotency race.** Verify a unique constraint on `(business_id,device_id,operation_id)` and make concurrent duplicate submissions safe. A read-before-insert alone is insufficient.
5. **Error disclosure.** The exception path currently stores the raw PostgreSQL error text in the operation result. Replace it with a stable, sanitized client error code; keep detailed diagnostics out of client-readable payloads.
6. **Legacy cost privacy.** Add adversarial tests for nested arrays/objects, item reorder/add/remove, all legacy cost-key aliases, and role changes. Verify private values cannot be overwritten or reattached to the wrong line item.
7. **Deletion and tombstones.** Define retention, restore, and cross-device tombstone behavior; ensure deletes cannot bypass posted-document reversal rules.
8. **Quota coverage.** The current draft applies invoice quotas but does not enforce the planned customer/product/service quotas. Quota checks must be server-side and idempotent.
9. **Payload validation.** Add allowlists per collection, payload size/depth limits, ID/date/amount validation, schema versioning, and rejection of client-controlled protected fields.
10. **Sync cursor tests.** Prove pagination and coalescing behavior under concurrent updates, role-filtered collections, tombstones, and more than one page.
11. **Device registration.** Validate public-key shape and bind device identity to an authenticated user with a revocation flow.
12. **RPC grants and schema exposure.** Verify private schema usage, function ownership, search_path, PUBLIC/anon revokes, authenticated grants, and wrapper behavior against the actual Supabase project settings.

## Minimum test gate before this draft can be reconsidered

- Clean install of predecessor migrations in a disposable Supabase/Postgres database.
- Migration rerun/rollback policy and schema-diff checks.
- Cross-business isolation and role matrix tests (including seller cannot read cost/profit).
- Duplicate operation and concurrent-write tests.
- Conflict handling across two devices.
- Invalid status / posted document / payment / cheque transition rejection.
- Cost privacy and tamper tests.
- Quota bypass and local-timezone boundary tests.
- Pagination, tombstone, and recovery tests.
- Legacy import reconciliation against source counts, balances, stock quantities, and historical profit.

No production migration should be run until the predecessor schema, these fixes, and the tests are complete and the final SQL package has been explicitly approved.
