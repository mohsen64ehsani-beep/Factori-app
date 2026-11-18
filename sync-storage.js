// Durable, per-business sync checkpoint storage.
// The business database and sync metadata are committed in one IndexedDB
// transaction so a cursor can never be persisted without its matching merge.
const DB_NAME = 'factoori-sync-state-v1';
const DB_VERSION = 1;
const STORE_NAME = 'checkpoints';

function requestResult(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error || new Error('IndexedDB request failed'));
  });
}

function transactionDone(transaction) {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = resolve;
    transaction.onabort = () => reject(transaction.error || new Error('IndexedDB transaction aborted'));
    transaction.onerror = () => reject(transaction.error || new Error('IndexedDB transaction failed'));
  });
}

export function openSyncCheckpointStore(indexedDBImpl = globalThis.indexedDB) {
  if (!indexedDBImpl?.open) return Promise.reject(new Error('IndexedDB is unavailable'));
  return new Promise((resolve, reject) => {
    const request = indexedDBImpl.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(STORE_NAME)) {
        db.createObjectStore(STORE_NAME, { keyPath: 'businessId' });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error || new Error('Unable to open sync checkpoint storage'));
    request.onblocked = () => reject(new Error('Sync checkpoint storage upgrade is blocked by another tab'));
  });
}

export async function loadSyncCheckpoint(businessId, indexedDBImpl) {
  if (!businessId) throw new Error('businessId is required');
  const db = await openSyncCheckpointStore(indexedDBImpl);
  try {
    const tx = db.transaction(STORE_NAME, 'readonly');
    // Attach completion handlers immediately: IndexedDB may complete the
    // transaction before the request promise continuation resumes.
    const done = transactionDone(tx);
    const result = await requestResult(tx.objectStore(STORE_NAME).get(String(businessId)));
    await done;
    return result || null;
  } finally {
    db.close();
  }
}

export async function commitSyncCheckpoint(businessId, dbSnapshot, syncState, indexedDBImpl) {
  if (!businessId) throw new Error('businessId is required');
  if (!dbSnapshot || typeof dbSnapshot !== 'object' || Array.isArray(dbSnapshot)) {
    throw new Error('dbSnapshot must be a database object');
  }
  if (!syncState || typeof syncState !== 'object' || !Number.isSafeInteger(Number(syncState.cursor)) || Number(syncState.cursor) < 0) {
    throw new Error('syncState cursor is invalid');
  }
  const db = await openSyncCheckpointStore(indexedDBImpl);
  try {
    const tx = db.transaction(STORE_NAME, 'readwrite');
    const done = transactionDone(tx);
    tx.objectStore(STORE_NAME).put({
      businessId: String(businessId),
      db: dbSnapshot,
      syncState,
      savedAt: Date.now(),
      schemaVersion: 1
    });
    await done;
    return true;
  } finally {
    db.close();
  }
}

export async function clearSyncCheckpoint(businessId, indexedDBImpl) {
  if (!businessId) throw new Error('businessId is required');
  const db = await openSyncCheckpointStore(indexedDBImpl);
  try {
    const tx = db.transaction(STORE_NAME, 'readwrite');
    const done = transactionDone(tx);
    tx.objectStore(STORE_NAME).delete(String(businessId));
    await done;
    return true;
  } finally {
    db.close();
  }
}
