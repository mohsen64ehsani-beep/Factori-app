// Explicit, testable coordinator for a single selected business.
// index.html invokes this runtime and applies results only when the selected
// business generation and local database revision still match the run snapshot.
import {
  createSyncState,
  prepareSyncOperations,
  acknowledgeSyncResults,
  applySyncPullPage,
  createSyncTombstone
} from './sync-engine.js';
import { saveLocalDatabaseCheckpoint, loadLocalDatabaseCheckpoint, createLocalDatabaseSnapshot, mergeLocalChangesOntoCheckpoint, acknowledgeLocalDatabaseApplied } from './sync-db-adapter.js';

const activeRuns = new Set();
const deferredDeletes = new Map();

function queueDeferredDelete(businessId, collection, legacyId) {
  const rows = deferredDeletes.get(businessId) || [];
  if (!rows.some(row => row.collection === collection && row.legacyId === legacyId)) {
    rows.push({ collection, legacyId });
  }
  deferredDeletes.set(businessId, rows);
}

async function persistBusinessDeletion({ businessId, collection, legacyId, indexedDBImpl }) {
  const checkpoint = await loadLocalDatabaseCheckpoint({ businessId, indexedDBImpl });
  if (!checkpoint) return false;
  const nextState = createSyncTombstone(collection, legacyId, checkpoint.syncState);
  const before = checkpoint.syncState?.tombstones?.length || 0;
  if ((nextState.tombstones?.length || 0) === before) return false;
  await saveLocalDatabaseCheckpoint({
    businessId,
    database: checkpoint.database,
    baseDatabase: checkpoint.baseDatabase,
    syncState: nextState,
    indexedDBImpl
  });
  return true;
}

async function flushDeferredBusinessDeletions(businessId, indexedDBImpl) {
  while (deferredDeletes.has(businessId)) {
    const rows = deferredDeletes.get(businessId) || [];
    deferredDeletes.delete(businessId);
    for (const row of rows) {
      try {
        await persistBusinessDeletion({ businessId, ...row, indexedDBImpl });
      } catch (error) {
        queueDeferredDelete(businessId, row.collection, row.legacyId);
        console.warn('[Factoori sync deletion queue]', error);
      }
    }
    // On a storage failure, retain the item for a later run instead of spinning.
    if ((deferredDeletes.get(businessId) || []).length) break;
  }
}

export async function recordBusinessDeletion({ businessId, collection, legacyId, indexedDBImpl }) {
  if (typeof businessId !== 'string' || !businessId.trim()) return { queued: false };
  if (typeof collection !== 'string' || typeof legacyId !== 'string' || !legacyId) {
    throw new Error('شناسه رکورد حذف‌شده معتبر نیست.');
  }
  if (activeRuns.has(businessId)) {
    queueDeferredDelete(businessId, collection, legacyId);
    return { queued: true, deferred: true };
  }
  const queued = await persistBusinessDeletion({ businessId, collection, legacyId, indexedDBImpl });
  return { queued, deferred: false };
}

function isPermissionVersionMismatch(error) {
  const message = String(error?.message || '').toLowerCase();
  return message.includes('sync_permissions_changed') ||
    message.includes('permission version changed');
}

function makeOperationId() {
  if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();
  throw new Error('شناسه امن عملیات همگام‌سازی در این دستگاه در دسترس نیست.');
}

export async function runBusinessSync({
  businessId,
  database,
  syncState,
  api,
  createOperationId = makeOperationId,
  persistCheckpoint,
  indexedDBImpl,
  deviceName = 'Factoori device',
  platform = 'android',
  maxPullPages = 100,
  maxPermissionResets = 2
}) {
  if (typeof businessId !== 'string' || !businessId.trim()) {
    throw new Error('برای همگام‌سازی باید کسب‌وکار مشخصی انتخاب شده باشد.');
  }
  if (!database || typeof database !== 'object' || Array.isArray(database)) {
    throw new Error('پایگاه داده محلی معتبر نیست.');
  }
  if (!api?.ensureSyncDevice || !api?.syncPushBatches || !api?.syncPull || !api?.getSyncDeviceId) {
    throw new Error('سرویس همگام‌سازی کامل در دسترس نیست.');
  }
  if (activeRuns.has(businessId)) throw new Error('همگام‌سازی این کسب‌وکار از قبل در حال اجراست.');
  const pageLimit = Math.min(1000, Math.max(1, Number(maxPullPages) || 100));
  const resetLimit = Math.min(5, Math.max(0, Number(maxPermissionResets) || 0));
  activeRuns.add(businessId);

  let localDb;
  let baseDatabase;
  let state;
  try {
    localDb = createLocalDatabaseSnapshot(database);
    const savedCheckpoint = syncState ? null : await loadLocalDatabaseCheckpoint({ businessId, indexedDBImpl });
    if (savedCheckpoint?.database && savedCheckpoint?.baseDatabase) {
      localDb = mergeLocalChangesOntoCheckpoint({
        localDatabase: localDb,
        baseDatabase: savedCheckpoint.baseDatabase,
        checkpointDatabase: savedCheckpoint.database
      });
    }
    baseDatabase = createLocalDatabaseSnapshot(localDb);
    state = syncState
      ? JSON.parse(JSON.stringify(syncState))
      : savedCheckpoint?.syncState ? JSON.parse(JSON.stringify(savedCheckpoint.syncState)) : createSyncState();
  } catch (error) {
    // Initialization also belongs to the run lock's lifetime. Otherwise an
    // IndexedDB failure permanently blocks subsequent retries for this business.
    activeRuns.delete(businessId);
    throw error;
  }
  let deviceId = '';
  let pushedOperations = 0;
  let pulledRecords = 0;
  let totalPages = 0;
  let permissionResets = 0;
  let hasMore = false;

  const persist = async () => {
    const args = { businessId, database: localDb, baseDatabase, syncState: state };
    if (persistCheckpoint) await persistCheckpoint(args);
    else await saveLocalDatabaseCheckpoint({ ...args, indexedDBImpl });
  };

  const pushPending = async () => {
    const prepared = prepareSyncOperations(localDb, state, createOperationId);
    state = prepared.state;
    // Persist operation IDs and exact payloads before the network request so
    // a crash/retry cannot create a new logical operation.
    await persist();
    if (!prepared.operations.length) return 0;
    const results = await api.syncPushBatches({
      businessId, deviceId, operations: prepared.operations
    });
    if (!Array.isArray(results)) throw new Error('پاسخ ارسال همگام‌سازی معتبر نیست.');
    state = acknowledgeSyncResults(state, results);
    await persist();
    return prepared.operations.length;
  };

  const pullPages = async () => {
    let pages = 0;
    let sawReset = false;
    let more = false;
    while (pages < pageLimit) {
      const response = await api.syncPull({
        businessId, deviceId, sinceRevision: state.cursor, limit: 500
      });
      const applied = applySyncPullPage(localDb, state, response);
      localDb = applied.db;
      state = applied.state;
      pages++;
      totalPages++;
      pulledRecords += Array.isArray(response.records) ? response.records.length : 0;
      await persist();
      if (applied.resetRequired) {
        sawReset = true;
        permissionResets++;
        if (permissionResets > resetLimit) {
          throw new Error('سطح دسترسی کسب‌وکار چند بار تغییر کرد؛ همگام‌سازی برای ایمنی متوقف شد.');
        }
        continue;
      }
      more = applied.hasMore;
      if (!applied.hasMore) break;
    }
    hasMore = more || pages >= pageLimit;
    return { sawReset, pages, hasMore };
  };

  try {
    const proof = await api.ensureSyncDevice({ businessId, deviceName, platform });
    deviceId = proof?.device_id || proof?.deviceId || api.getSyncDeviceId(businessId);
    if (!deviceId || proof?.verified === false) {
      throw new Error('تأیید امن این دستگاه برای همگام‌سازی انجام نشد.');
    }

    const resumingPermissionReset = state.permissionResetInProgress === true;
    let permissionMismatch = false;
    if (!resumingPermissionReset) {
      try {
        pushedOperations += await pushPending();
      } catch (error) {
        if (!isPermissionVersionMismatch(error)) throw error;
        permissionMismatch = true;
      }
    }

    const firstPull = await pullPages();
    if ((permissionMismatch || firstPull.sawReset || resumingPermissionReset) && !firstPull.hasMore) {
      pushedOperations += await pushPending();
      if (!hasMore) await pullPages();
    }

    await persist();
    return {
      businessId,
      deviceId,
      database: createLocalDatabaseSnapshot(localDb),
      syncState: state,
      pushedOperations,
      pulledRecords,
      pages: totalPages,
      permissionResets,
      hasMore
    };
  } finally {
    await flushDeferredBusinessDeletions(businessId, indexedDBImpl);
    activeRuns.delete(businessId);
  }
}

export function isSyncPermissionVersionMismatch(error) {
  return isPermissionVersionMismatch(error);
}

if (typeof window !== 'undefined') {
  window.FactooriSyncRuntime = Object.freeze({
    runBusinessSync,
    isSyncPermissionVersionMismatch,
    acknowledgeBusinessDatabaseApplied,
    recordBusinessDeletion
  });
  window.dispatchEvent(new Event('factoori-sync-runtime-ready'));
}


export async function acknowledgeBusinessDatabaseApplied({ businessId, database, syncState, indexedDBImpl }) {
  return acknowledgeLocalDatabaseApplied({ businessId, database, syncState, indexedDBImpl });
}
