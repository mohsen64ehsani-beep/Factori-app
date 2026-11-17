# 007 invitations and member administration — review gates

Status: DEVELOPMENT DRAFT ONLY — NOT EXECUTED.

Adds business invitation records, immutable audit log, invitation acceptance/revocation, member role updates, member suspension/removal, and per-member allow/deny permission overrides.

## Security decisions
- Invitation acceptance requires an authenticated account whose verified/current Auth email matches the invited address.
- The invitation token is stored only as a 64-character SHA-256 hex hash. The caller generating/sending the email link must create the random token and hash it outside this SQL function.
- Only the owner may invite or assign another administrator.
- No RPC can assign or remove the owner role. Ownership transfer is a separate future workflow.
- Sensitive permissions (member management, posting, payment, inventory and profit/cost access) can only be granted by the owner; administrators may deny permissions but cannot elevate a member into those sensitive capabilities.
- Permission overrides are enforced by the existing database permission helper, not merely hidden in the UI.
- Membership and invitation writes are available only through narrowly scoped RPCs; direct table writes remain revoked.
- Member changes and invitation actions append audit records; audit logs have no client write/update/delete grants.

## Blocking work
1. Implement and test token generation, hashing and email delivery in a trusted Edge Function; never send token_hash itself to users.
2. Confirm Supabase Auth email confirmation/verified-email behavior and require verified email before acceptance.
3. Add rate limits, invitation resend cooldown, pending invite expiry processing, and abuse protection.
4. Decide whether administrators may invite accountants/sales/viewers and confirm role hierarchy with the product UI.
5. Add ownership transfer, account deletion/retention, and recovery for a departed owner.
6. Add concurrency tests for duplicate invites, simultaneous acceptance, role changes and suspension.
7. Verify audit metadata never contains tokens, passwords, private cost data or sensitive payment details.
8. Test allow/deny overrides, role-default inheritance, sensitive grant restrictions, and immediate RLS enforcement after a permission change.

No invitation email is sent by this SQL migration. Apply only in disposable staging after migration 001.
