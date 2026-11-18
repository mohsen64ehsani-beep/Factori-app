// Explicit, synchronous business switching for the legacy local db:v2 model.
// The caller must persist the returned database into its in-memory db object
// before rendering. This module never changes auth, cloud membership or server data.
import {
  loadBusinessDatabase,
  saveBusinessDatabase,
  adoptLegacyDatabaseForBusiness
} from './business-db-scope.js';

export function switchLocalBusinessDatabase({
  storage,
  currentBusinessId,
  nextBusinessId,
  currentDatabase,
  confirmLegacyAdoption = false
}) {
  if (typeof nextBusinessId !== 'string' || !nextBusinessId.trim()) {
    throw new Error('Select a valid business before switching');
  }
  const nextId = nextBusinessId.trim();
  if (currentBusinessId && currentBusinessId === nextId) {
    return { changed: false, businessId: nextId, database: currentDatabase };
  }
  // Save the previous tenant's in-memory state before looking up the next one.
  // Never save the unscoped legacy db into a business unless explicitly adopted.
  if (currentBusinessId) {
    saveBusinessDatabase({
      storage,
      businessId: currentBusinessId,
      database: currentDatabase
    });
  }
  let database = loadBusinessDatabase({ storage, businessId: nextId });
  let adoptedLegacy = false;
  if (!database && confirmLegacyAdoption) {
    const result = adoptLegacyDatabaseForBusiness({
      storage,
      businessId: nextId,
      confirmed: true
    });
    if (result.adopted) {
      database = result.database;
      adoptedLegacy = true;
    }
  }
  return {
    changed: true,
    businessId: nextId,
    database: database || null,
    adoptedLegacy,
    requiresEmptyDatabase: !database
  };
}
