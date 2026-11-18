// Resolve startup storage without ever attaching unscoped db:v2 data
// to an authenticated business automatically.
import {
  LEGACY_DATABASE_KEY,
  loadBusinessDatabase,
  adoptLegacyDatabaseForBusiness
} from './business-db-scope.js';

export function resolveInitialBusinessDatabase({
  storage,
  businessId,
  legacyAdoptionConfirmed = false
}) {
  if (typeof businessId !== 'string' || !businessId.trim()) {
    return {
      status: 'no_business',
      businessId: '',
      database: null,
      legacyAvailable: storage.getItem(LEGACY_DATABASE_KEY) != null
    };
  }
  const id = businessId.trim();
  const scoped = loadBusinessDatabase({ storage, businessId: id });
  if (scoped) {
    return { status: 'loaded', businessId: id, database: scoped, legacyAvailable: false };
  }
  if (legacyAdoptionConfirmed) {
    const result = adoptLegacyDatabaseForBusiness({
      storage, businessId: id, confirmed: true
    });
    if (result.adopted) {
      return {
        status: 'adopted',
        businessId: id,
        database: result.database,
        legacyAvailable: true
      };
    }
    return {
      status: 'adoption_blocked',
      businessId: id,
      database: null,
      reason: result.reason,
      legacyAvailable: storage.getItem(LEGACY_DATABASE_KEY) != null
    };
  }
  return {
    status: 'needs_legacy_decision',
    businessId: id,
    database: null,
    legacyAvailable: storage.getItem(LEGACY_DATABASE_KEY) != null
  };
}
