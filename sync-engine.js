// Factoori local/shared sync primitives. Intentionally not wired to db:v2 until
// local save/delete hooks and financial posting flows are covered by integration tests.
export const SYNC_WRITE_COLLECTIONS = Object.freeze([
  'cust', 'suppliers', 'duedates', 'prod', 'services', 'categories',
  'inv', 'serviceInv', 'warehouses', 'bankAccounts', 'fiscal',
  'smsHistory'
]);

export const SYNC_READ_COLLECTIONS = Object.freeze([
  ...SYNC_WRITE_COLLECTIONS, 'debt', 'returns', 'pay', 'creditors',
  'creditorPayments', 'purchases', 'supplierPayments', 'expenses',
  'otherincome', 'wastage', 'stockMoves', 'warehouseStocks',
  'transfers', 'accounts', 'moneytransfers', 'opening'
]);

const WRITE_SET = new Set(SYNC_WRITE_COLLECTIONS);
const READ_SET = new Set(SYNC_READ_COLLECTIONS);

const SENSITIVE_LOCAL_KEYS = new Set([
  'buy','b','cost','costTotal','cost_total','unitCostAtReturn','unit_cost_at_return',
  'unit_cost','unitCost','buyPrice','purchasePrice','costPrice','cost_price','total_cost',
  'last_purchase_cost','average_cost','averageCost','avgCost','average_unit_cost','inventory_value',
  'profit','profitAmount','margin','marginAmount','purchase_cost','cost_snapshot','unit_cost_snapshot'
]);

function stripSensitiveLocalValue(value) {
  if (Array.isArray(value)) return value.map(stripSensitiveLocalValue);
  if (!value || typeof value !== 'object') return value;
  const result = {};
  for (const [key, item] of Object.entries(value)) {
    if (!SENSITIVE_LOCAL_KEYS.has(key)) result[key] = stripSensitiveLocalValue(item);
  }
  return result;
}

function resetAfterPermissionVersionChange(db, state) {
  const nextDb = { ...db };
  for (const collection of SYNC_READ_COLLECTIONS) {
    if (Array.isArray(db[collection])) nextDb[collection] = stripSensitiveLocalValue(db[collection]);
  }
  const nextState = ensureState(state);
  // Pending payloads may contain data captured under the previous permission
  // set. Quarantine sanitized copies; local records remain in nextDb and can
  // be re-enqueued against their last acknowledged snapshot.
  nextState.conflicts.push(...nextState.pending.map(operation => ({
    operation: stripSensitiveLocalValue(operation),
    reason: 'permission_version_changed',
    detected_at: Date.now()
  })));
  nextState.pending = [];
  for (const collection of Object.keys(nextState.snapshots)) {
    for (const [legacyId, fingerprint] of Object.entries(nextState.snapshots[collection] || {})) {
      try {
        nextState.snapshots[collection][legacyId] = stableStringify(
          stripSensitiveLocalValue(JSON.parse(fingerprint))
        );
      } catch {
        delete nextState.snapshots[collection][legacyId];
      }
    }
  }
  nextState.cursor = 0;
  return { db: nextDb, state: nextState };
}

export function createSyncState() {
  return { cursor: 0, versions: {}, snapshots: {}, pending: [], conflicts: [], rejected: [], tombstones: [] };
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

export function stableStringify(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return '[' + value.map(stableStringify).join(',') + ']';
  return '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + stableStringify(value[key])).join(',') + '}';
}

function normalizeLocalRecord(collection, record) {
  if (record === null || record === undefined) return null;
  if (typeof record === 'string' || typeof record === 'number') {
    if (!['services', 'categories'].includes(collection)) return null;
    const value = String(record);
    return { legacyId: 'value:' + value, payload: { value }, localValue: value };
  }
  if (typeof record !== 'object' || Array.isArray(record) || record.id === null || record.id === undefined) return null;
  const legacyId = String(record.id);
  if (!legacyId || legacyId.length > 200) return null;
  return { legacyId, payload: clone(record), localValue: clone(record) };
}

function ensureState(state) {
  const next = state && typeof state === 'object' ? clone(state) : createSyncState();
  for (const key of ['versions', 'snapshots']) if (!next[key] || typeof next[key] !== 'object') next[key] = {};
  for (const key of ['pending', 'conflicts', 'rejected', 'tombstones']) if (!Array.isArray(next[key])) next[key] = [];
  next.cursor = Math.max(0, Number(next.cursor) || 0);
  return next;
}

export function prepareSyncOperations(db, state, createOperationId) {
  if (typeof createOperationId !== 'function') throw new Error('operation id generator is required');
  const next = ensureState(state);
  const queued = new Set(next.pending.map(op => op.collection + ':' + op.legacy_id));
  const operations = next.pending.map(clone);

  for (const collection of SYNC_WRITE_COLLECTIONS) {
    const rows = db?.[collection];
    if (!Array.isArray(rows)) continue;
    for (const row of rows) {
      const normalized = normalizeLocalRecord(collection, row);
      if (!normalized) continue;
      const { legacyId, payload } = normalized;
      const key = collection + ':' + legacyId;
      if (queued.has(key)) continue;
      const fingerprint = stableStringify(payload);
      if (next.snapshots[collection]?.[legacyId] === fingerprint) continue;
      const operation = {
        operation_id: createOperationId(),
        collection,
        operation_type: 'upsert',
        legacy_id: legacyId,
        base_version: Math.max(0, Number(next.versions[collection]?.[legacyId]) || 0),
        payload
      };
      next.pending.push(operation);
      operations.push(operation);
      queued.add(key);
    }
  }

  for (const tombstone of next.tombstones) {
    if (!tombstone || !WRITE_SET.has(tombstone.collection) || !tombstone.legacy_id) continue;
    const key = tombstone.collection + ':' + String(tombstone.legacy_id);
    if (queued.has(key)) continue;
    const baseVersion = Math.max(0, Number(next.versions[tombstone.collection]?.[tombstone.legacy_id]) || 0);
    if (!baseVersion) continue; // Never issue a delete for a record not known to exist remotely.
    const operation = {
      operation_id: createOperationId(),
      collection: tombstone.collection,
      operation_type: 'delete',
      legacy_id: String(tombstone.legacy_id),
      base_version: baseVersion
    };
    next.pending.push(operation);
    operations.push(operation);
    queued.add(key);
  }
  return { state: next, operations };
}

export function acknowledgeSyncResults(state, results) {
  const next = ensureState(state);
  if (!Array.isArray(results)) throw new Error('sync results must be an array');
  const byId = new Map(next.pending.map(op => [op.operation_id, op]));
  const completed = new Set();
  for (const result of results) {
    const operation = byId.get(result?.operation_id);
    if (!operation) continue;
    if (result.status === 'applied' || result.status === 'duplicate') {
      const version = Number(result.version ?? result.current_version);
      if (Number.isFinite(version) && version >= 0) {
        next.versions[operation.collection] ||= {};
        next.versions[operation.collection][operation.legacy_id] = version;
      }
      if (operation.operation_type === 'delete') {
        if (next.snapshots[operation.collection]) delete next.snapshots[operation.collection][operation.legacy_id];
        next.tombstones = next.tombstones.filter(t => !(t.collection === operation.collection && String(t.legacy_id) === operation.legacy_id));
      } else {
        next.snapshots[operation.collection] ||= {};
        next.snapshots[operation.collection][operation.legacy_id] = stableStringify(operation.payload);
      }
      completed.add(operation.operation_id);
    } else if (result.status === 'conflict') {
      next.conflicts.push({ operation, current_version: Number(result.current_version) || 0, detected_at: Date.now() });
      completed.add(operation.operation_id);
    } else if (result.status === 'rejected') {
      next.rejected.push({ operation, error_code: result.error_code || 'operation_rejected', detected_at: Date.now() });
      completed.add(operation.operation_id);
    }
  }
  next.pending = next.pending.filter(op => !completed.has(op.operation_id));
  return next;
}

export function applyPulledRecords(db, state, records) {
  if (!db || typeof db !== 'object' || !Array.isArray(records)) throw new Error('invalid pull target or records');
  const nextState = ensureState(state);
  const nextDb = { ...db };
  for (const collection of SYNC_READ_COLLECTIONS) {
    nextDb[collection] = Array.isArray(db[collection]) ? db[collection].map(clone) : [];
  }
  const dirty = new Set(nextState.pending.map(op => op.collection + ':' + op.legacy_id));
  for (const collection of SYNC_READ_COLLECTIONS) {
    if (!Array.isArray(nextDb[collection])) nextDb[collection] = [];
  }
  for (const record of records) {
    const collection = record?.collection;
    const legacyId = String(record?.legacy_id ?? '');
    if (!READ_SET.has(collection) || !legacyId) continue;
    const key = collection + ':' + legacyId;
    if (dirty.has(key)) {
      nextState.conflicts.push({ remote_record: clone(record), reason: 'local_pending_change' });
      continue;
    }
    const rows = nextDb[collection];
    const index = rows.findIndex(row => String(
      row && typeof row === 'object' && row.id !== undefined ? row.id :
      (typeof row === 'string' || typeof row === 'number') ? 'value:' + row : ''
    ) === legacyId);
    if (record.deleted_at || record.change_type === 'delete') {
      if (index >= 0) rows.splice(index, 1);
      if (nextState.snapshots[collection]) delete nextState.snapshots[collection][legacyId];
    } else {
      const payload = record.payload && typeof record.payload === 'object' && !Array.isArray(record.payload) ? clone(record.payload) : null;
      if (!payload) continue;
      const value = ['services', 'categories'].includes(collection) && Object.keys(payload).length === 1 && typeof payload.value === 'string'
        ? payload.value : payload;
      if (index >= 0) rows[index] = value;
      else rows.push(value);
      nextState.snapshots[collection] ||= {};
      nextState.snapshots[collection][legacyId] = stableStringify(payload);
    }
    if (Number.isFinite(Number(record.version))) {
      nextState.versions[collection] ||= {};
      nextState.versions[collection][legacyId] = Number(record.version);
    }
  }
  return { db: nextDb, state: nextState };
}


export function createSyncTombstone(collection, legacyId, state) {
  if (!WRITE_SET.has(collection)) throw new Error('collection is not enabled for sync deletes');
  const id = String(legacyId ?? '');
  if (!id || id.length > 200) throw new Error('invalid tombstone legacy id');
  const next = ensureState(state);
  const knownVersion = Number(next.versions[collection]?.[id]) || 0;
  if (knownVersion <= 0) return next;
  if (!next.tombstones.some(item => item.collection === collection && String(item.legacy_id) === id)) {
    next.tombstones.push({ collection, legacy_id: id, created_at: Date.now() });
  }
  return next;
}

export function advanceSyncCursor(state, cursor) {
  const next = ensureState(state);
  const value = Number(cursor);
  if (!Number.isSafeInteger(value) || value < next.cursor) throw new Error('sync cursor must be a non-decreasing safe integer');
  next.cursor = value;
  return next;
}

// Apply one SQL sync_pull page. The cursor advances only after the records merge
// has completed successfully; callers must persist the returned db and state
// together before requesting the next page.
export function applySyncPullPage(db, state, response) {
  if (!response || typeof response !== 'object' || Array.isArray(response)) {
    throw new Error('invalid sync pull response');
  }
  if (response.reset_required === true) {
    const reset = resetAfterPermissionVersionChange(db, state);
    return { db: reset.db, state: reset.state, resetRequired: true, hasMore: true };
  }
  if (!Array.isArray(response.records)) throw new Error('sync pull response records must be an array');
  if (typeof response.has_more !== 'boolean') throw new Error('sync pull response has_more must be boolean');
  const currentState = ensureState(state);
  const cursor = Number(response.next_cursor);
  if (!Number.isSafeInteger(cursor) || cursor < currentState.cursor) {
    throw new Error('sync pull response cursor is invalid or moved backwards');
  }
  const merged = applyPulledRecords(db, currentState, response.records);
  const nextState = advanceSyncCursor(merged.state, cursor);
  return {
    db: merged.db,
    state: nextState,
    resetRequired: false,
    hasMore: response.has_more
  };
}

