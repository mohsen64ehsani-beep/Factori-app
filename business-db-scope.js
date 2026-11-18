// Business-scoped legacy database storage primitives.
// Deliberately not wired into the UI: adopting the old unscoped db:v2 data
// must be an explicit user decision to avoid assigning one business's data
// to another business after account switching.
export const LEGACY_DATABASE_KEY = 'db:v2';
export const BUSINESS_DATABASE_PREFIX = 'db:v2:business:';
export const LEGACY_ADOPTION_MARKER = 'factoori:db-v2:legacy-adopted';

function requireStorage(storage) {
  if (!storage || typeof storage.getItem !== 'function'
    || typeof storage.setItem !== 'function') {
    throw new Error('A compatible storage implementation is required');
  }
  return storage;
}

function businessKey(businessId) {
  if (typeof businessId !== 'string' || !businessId.trim()) {
    throw new Error('An explicit business ID is required');
  }
  return BUSINESS_DATABASE_PREFIX + encodeURIComponent(businessId.trim());
}

function parseDatabase(raw) {
  if (raw == null) return null;
  const value = JSON.parse(raw);
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('Stored business database is invalid');
  }
  return value;
}

export function loadBusinessDatabase({ storage, businessId }) {
  const target = requireStorage(storage);
  const key = businessKey(businessId);
  return parseDatabase(target.getItem(key));
}

export function saveBusinessDatabase({ storage, businessId, database }) {
  const target = requireStorage(storage);
  const key = businessKey(businessId);
  if (!database || typeof database !== 'object' || Array.isArray(database)) {
    throw new Error('Database must be an object');
  }
  const serialized = JSON.stringify(database);
  if (typeof serialized !== 'string') throw new Error('Database serialization failed');
  target.setItem(key, serialized);
  return key;
}

export function adoptLegacyDatabaseForBusiness({
  storage,
  businessId,
  confirmed = false
}) {
  const target = requireStorage(storage);
  const key = businessKey(businessId);
  if (confirmed !== true) {
    return { adopted: false, reason: 'confirmation_required', key };
  }
  const existing = target.getItem(key);
  if (existing != null) {
    return { adopted: false, reason: 'business_database_exists', key };
  }
  if (target.getItem(LEGACY_ADOPTION_MARKER) != null) {
    return { adopted: false, reason: 'legacy_database_already_assigned', key };
  }
  const legacy = target.getItem(LEGACY_DATABASE_KEY);
  if (legacy == null) {
    return { adopted: false, reason: 'legacy_database_missing', key };
  }
  // Validate before writing. Keep a durable "pending" claim first so a second
  // tab cannot assign the same legacy data to another business during adoption.
  // A crash may leave a pending marker (fail-closed); the legacy source remains
  // untouched and can be recovered manually. localStorage has no transactions.
  const parsed = parseDatabase(legacy);
  const claim = {
    businessId: businessId.trim(),
    adoptedAt: new Date().toISOString(),
    source: LEGACY_DATABASE_KEY,
    state: 'pending'
  };
  target.setItem(LEGACY_ADOPTION_MARKER, JSON.stringify(claim));
  try {
    target.setItem(key, JSON.stringify(parsed));
  } catch (error) {
    // Roll back the claim only when storage explicitly supports removal.
    // If rollback itself fails, leave the claim in place to prevent data leakage.
    try {
      if (typeof target.removeItem === 'function') target.removeItem(LEGACY_ADOPTION_MARKER);
    } catch (_) {}
    throw error;
  }
  target.setItem(LEGACY_ADOPTION_MARKER, JSON.stringify({
    ...claim,
    state: 'committed'
  }));
  return { adopted: true, key, database: parsed };
}
