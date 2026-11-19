-- These private license tables are accessed only by postgres-owned SECURITY DEFINER
-- routines. They intentionally have no client-facing table grants or RLS policies.
-- Enabling RLS adds defense in depth while the table owner remains able to run
-- the audited license RPCs (FORCE ROW LEVEL SECURITY is deliberately not enabled).
alter table private.factori_license_entitlements enable row level security;
alter table private.factori_license_entitlement_events enable row level security;
