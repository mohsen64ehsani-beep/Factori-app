# 001 identity and tenancy foundation — review notes

Status: **DEVELOPMENT DRAFT ONLY — NOT EXECUTED**

This migration is intended to establish the shared Auth identity, business tenancy, roles, permission catalog, and the minimum API currently expected by \`cloud-client.js\`.

## Compatibility
- \`profiles.id\` references \`auth.users.id\`; sign-up display name is read from \`raw_user_meta_data.display_name\`.
- \`business_members\` exposes \`business_id,user_id,role_code,status\` used by the current client.
- \`businesses\` exposes \`id,name,status,owner_user_id\`.
- \`business_settings\` is provisioned on business creation.
- \`create_business(p_name)\` and \`get_business_entitlements(p_business_id)\` are the currently probed RPC names.

## Important scope limits
- The entitlements RPC returns \`plan_status=pending_entitlements\`; it is a connectivity/authorization placeholder, not subscription enforcement.
- There are no invitation, member-management, role-change, audit, normalized ledger, inventory, document, or sync tables in this migration.
- No client is allowed to insert or update business membership or role-permission data directly. Those operations need separately reviewed owner/admin RPCs.
- Role permissions are conservative defaults. Seller has no cost or profit permissions.
- Existing license tables and activation flows are not modified.

## Required fixes before production approval
1. Add a business-membership invariant ensuring the \`businesses.owner_user_id\` always has exactly one active \`owner\` membership. Enforce owner transfer and deletion through audited RPCs only.
2. Add and test RLS policies for every future table before granting access; no generic tenant policy shortcuts.
3. Add explicit profile field validation and decide whether users can edit their own display name.
4. Decide whether archived/suspended businesses should be visible to owners; current helper functions intentionally block access unless business status is active.
5. Add updated_at triggers to mutable tables and verify that profiles cannot alter protected fields.
6. Confirm whether Supabase allows this project role to create schema \`private\`, alter \`auth.users\` triggers, and set function ownership as expected. Run only in disposable staging first.
7. Test signup with email confirmation enabled and disabled, profile trigger failure behavior, business creation, cross-tenant access, and role overrides.
8. Reconcile all permission codes with the UI and future RPCs before enabling production features.
9. Add subscription/feature entitlement enforcement before any paid/free limit is considered active.
10. Add rate limits and abuse protection to business creation.

Do not apply this draft to the live project until the full SQL, staging tests, rollback plan, and explicit user approval are ready.
