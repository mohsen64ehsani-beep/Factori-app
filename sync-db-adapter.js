// Safe bridge between the legacy db:v2 object and durable local sync checkpoints.
// This adapter only stores a local snapshot. It does not contact Supabase or
// alter localStorage; callers must supply an explicitly selected business ID.
import { commitSyncCheckpoint, loadSyncCheckpoint } from './sync-storage.js';

export function createLocalDatabaseSnapshot(database) {
  if (!database || typeof database !== 'object' || Array.isArray(database)) {
    throw new Error('Local database must be an object');
  }
  // db:v2 is JSON-backed. Round-tripping creates a detached, serializable
  // snapshot and fails closed if unexpected non-JSON values are present.
  let snapshot;
  try {
    snapshot = JSON.parse(JSON.stringify(database));
  } catch {
    throw new Error('Local database cannot be serialized safely');
  }
  if (!snapshot || typeof snapshot !== 'object' || Array.isArray(snapshot)) {
    throw new Error('Local database snapshot is invalid');
  }
  return snapshot;
}

export async function saveLocalDatabaseCheckpoint({
  businessId,
  database,
  syncState,
  indexedDBImpl
}) {
  if (typeof businessId !== 'string' || !businessId.trim()) {
    throw new Error('An explicitly selected business is required');
  }
  const snapshot = createLocalDatabaseSnapshot(database);
  await commitSyncCheckpoint(businessId, snapshot, syncState, indexedDBImpl);
  return { saved: true, businessId, snapshot };
}

export async function loadLocalDatabaseCheckpoint({ businessId, indexedDBImpl }) {
  if (typeof businessId !== 'string' || !businessId.trim()) {
    throw new Error('An explicitly selected business is required');
  }
  const checkpoint = await loadSyncCheckpoint(businessId, indexedDBImpl);
  if (!checkpoint) return null;
  return {
    businessId,
    database: createLocalDatabaseSnapshot(checkpoint.db),
    syncState: checkpoint.syncState
  };
}
