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
  baseDatabase = database,
  indexedDBImpl
}) {
  if (typeof businessId !== 'string' || !businessId.trim()) {
    throw new Error('An explicitly selected business is required');
  }
  const snapshot = createLocalDatabaseSnapshot(database);
  const baseline = createLocalDatabaseSnapshot(baseDatabase);
  await commitSyncCheckpoint(businessId, snapshot, syncState, indexedDBImpl, baseline);
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
    baseDatabase: createLocalDatabaseSnapshot(checkpoint.baseDb || checkpoint.db),
    syncState: checkpoint.syncState
  };
}


function sameJson(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

function rowIdentity(value, index) {
  if (value && typeof value === 'object' && !Array.isArray(value) && value.id !== undefined && value.id !== null) {
    return 'id:' + String(value.id);
  }
  if (typeof value === 'string' || typeof value === 'number') return 'value:' + String(value);
  return 'index:' + index;
}

// Recover a checkpoint after a process interruption without discarding edits
// made in localStorage since that sync run began. The baseDatabase is the exact
// local snapshot captured before the run; only local deltas are overlaid.
export function mergeLocalChangesOntoCheckpoint({ localDatabase, baseDatabase, checkpointDatabase }) {
  const local = createLocalDatabaseSnapshot(localDatabase);
  const base = createLocalDatabaseSnapshot(baseDatabase);
  const checkpoint = createLocalDatabaseSnapshot(checkpointDatabase);
  const merged = { ...checkpoint };
  const keys = new Set([...Object.keys(base), ...Object.keys(local), ...Object.keys(checkpoint)]);

  for (const key of keys) {
    const before = base[key];
    const current = local[key];
    const remote = checkpoint[key];
    if (sameJson(before, current)) continue;

    if (Array.isArray(before) && Array.isArray(current) && Array.isArray(remote)) {
      // Collections without stable row IDs cannot be safely merged by position
      // or value (duplicates are valid). Preserve the user's complete local
      // version rather than silently dropping or misidentifying entries.
      const hasStableIds = [...before, ...current, ...remote].every(value =>
        value && typeof value === 'object' && !Array.isArray(value) && value.id !== undefined && value.id !== null
      );
      if (!hasStableIds) {
        merged[key] = current;
        continue;
      }
      const beforeMap = new Map(before.map((value, index) => [rowIdentity(value, index), value]));
      const currentMap = new Map(current.map((value, index) => [rowIdentity(value, index), value]));
      const changed = new Set();
      for (const [id, value] of currentMap) {
        if (!beforeMap.has(id) || !sameJson(beforeMap.get(id), value)) changed.add(id);
      }
      const deleted = new Set([...beforeMap.keys()].filter(id => !currentMap.has(id)));
      const result = remote.filter((value, index) => !deleted.has(rowIdentity(value, index)))
        .map(value => {
          const id = rowIdentity(value, remote.indexOf(value));
          return changed.has(id) ? currentMap.get(id) : value;
        });
      const present = new Set(result.map((value, index) => rowIdentity(value, index)));
      for (const [id, value] of currentMap) if (changed.has(id) && !present.has(id)) result.push(value);
      merged[key] = result;
    } else {
      merged[key] = current;
    }
  }
  return createLocalDatabaseSnapshot(merged);
}


export async function acknowledgeLocalDatabaseApplied({ businessId, database, syncState, indexedDBImpl }) {
  return saveLocalDatabaseCheckpoint({
    businessId,
    database,
    baseDatabase: database,
    syncState,
    indexedDBImpl
  });
}
