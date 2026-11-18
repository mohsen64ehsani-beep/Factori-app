import test from 'node:test';
import assert from 'node:assert/strict';
import {
  createSyncState, prepareSyncOperations, acknowledgeSyncResults,
  applyPulledRecords, advanceSyncCursor
} from './sync-engine.js';

const ids = (() => { let n = 0; return () => '00000000-0000-4000-8000-' + String(++n).padStart(12, '0'); })();

test('only explicitly write-enabled collections produce operations', () => {
  const { operations } = prepareSyncOperations({
    cust: [{ id: 1, n: 'A' }], pay: [{ id: 2, amount: 10 }],
    purchases: [{ id: 3, amount: 20 }], accounts: [{ id: 4, name: 'Cash' }]
  }, createSyncState(), ids);
  assert.deepEqual(operations.map(op => op.collection), ['cust']);
});

test('new records use base version zero and stable legacy ids', () => {
  const { operations } = prepareSyncOperations({ cust: [{ id: 17, n: 'مشتری' }] }, createSyncState(), ids);
  assert.equal(operations[0].legacy_id, '17');
  assert.equal(operations[0].base_version, 0);
  assert.equal(operations[0].operation_type, 'upsert');
});

test('unchanged records are not re-enqueued after successful acknowledgement', () => {
  const db = { cust: [{ id: 'c1', n: 'A' }] };
  const first = prepareSyncOperations(db, createSyncState(), ids);
  const ack = acknowledgeSyncResults(first.state, [{ operation_id: first.operations[0].operation_id, status: 'applied', version: 1 }]);
  assert.equal(prepareSyncOperations(db, ack, ids).operations.length, 0);
});

test('pending operation identity and payload survive retries', () => {
  const first = prepareSyncOperations({ prod: [{ id: 'p1', n: 'X' }] }, createSyncState(), ids);
  const retry = prepareSyncOperations({ prod: [{ id: 'p1', n: 'Y' }] }, first.state, ids);
  assert.equal(retry.operations[0].operation_id, first.operations[0].operation_id);
  assert.deepEqual(retry.operations[0].payload, { id: 'p1', n: 'X' });
});

test('conflicts are quarantined and not silently overwritten', () => {
  const first = prepareSyncOperations({ cust: [{ id: 'c1', n: 'local' }] }, createSyncState(), ids);
  const state = acknowledgeSyncResults(first.state, [{ operation_id: first.operations[0].operation_id, status: 'conflict', current_version: 4 }]);
  assert.equal(state.pending.length, 0);
  assert.equal(state.conflicts.length, 1);
  assert.equal(state.conflicts[0].current_version, 4);
});

test('pull applies remote records, preserves dirty local records, and handles tombstones', () => {
  const initial = createSyncState();
  const stateWithPending = {
    ...initial,
    pending: [{ operation_id: 'pending-1', collection: 'cust', legacy_id: 'local-1', operation_type: 'upsert', base_version: 0, payload: { id: 'local-1', n: 'dirty' } }]
  };
  const inputDb = { cust: [{ id: 'local-1', n: 'dirty' }, { id: 'old', n: 'remove' }] };
  const { db, state } = applyPulledRecords(inputDb, stateWithPending, [
    { collection: 'cust', legacy_id: 'local-1', version: 1, payload: { id: 'local-1', n: 'remote' } },
    { collection: 'cust', legacy_id: 'old', version: 2, deleted_at: '2026-01-01T00:00:00Z' },
    { collection: 'prod', legacy_id: 'p1', version: 1, payload: { id: 'p1', n: 'remote product' } }
  ]);
  assert.equal(db.cust[0].n, 'dirty');
  assert.equal(db.cust.length, 1, 'remote tombstone should be applied to the returned database');
  assert.equal(inputDb.cust.length, 2, 'pull merge must not mutate the caller\'s local database');
  assert.equal(stateWithPending.pending.length, 1, 'input sync state must remain immutable');
  assert.equal(db.prod[0].n, 'remote product');
  assert.equal(state.conflicts.length, 1);
});

test('primitive service/category values get stable object payloads', () => {
  const { operations } = prepareSyncOperations({ categories: ['خوراکی'] }, createSyncState(), ids);
  assert.equal(operations[0].legacy_id, 'value:خوراکی');
  assert.deepEqual(operations[0].payload, { value: 'خوراکی' });
});

test('explicit tombstones delete only records with a known remote version', () => {
  const state = { ...createSyncState(), versions: { cust: { c1: 3 } }, tombstones: [{ collection: 'cust', legacy_id: 'c1' }, { collection: 'cust', legacy_id: 'unknown' }] };
  const { operations } = prepareSyncOperations({}, state, ids);
  assert.equal(operations.length, 1);
  assert.equal(operations[0].operation_type, 'delete');
  assert.equal(operations[0].base_version, 3);
});


test('tombstone helper only records explicitly deleted remotely-known records', async () => {
  const { createSyncTombstone } = await import('./sync-engine.js');
  const initial = { ...createSyncState(), versions: { cust: { c1: 4 } } };
  const next = createSyncTombstone('cust', 'c1', initial);
  assert.equal(next.tombstones.length, 1);
  assert.equal(next.tombstones[0].legacy_id, 'c1');
  assert.equal(initial.tombstones.length, 0);
  assert.equal(createSyncTombstone('cust', 'unknown', initial).tombstones.length, 0);
  assert.throws(() => createSyncTombstone('pay', 'p1', initial));
});

test('cursor cannot move backwards or exceed safe integer precision', () => {
  const state = advanceSyncCursor(createSyncState(), 9);
  assert.equal(state.cursor, 9);
  assert.throws(() => advanceSyncCursor(state, 8));
  assert.throws(() => advanceSyncCursor(state, Number.MAX_SAFE_INTEGER + 1));
});

test('SQL pull envelope is validated and cursor advances only after successful merge', async () => {
  const { applySyncPullPage } = await import('./sync-engine.js');
  const initialDb = { cust: [{ id: 'c1', n: 'local' }] };
  const initialState = createSyncState();
  const applied = applySyncPullPage(initialDb, initialState, {
    records: [{ collection: 'cust', legacy_id: 'c1', version: 2, revision: 8, change_type: 'upsert', deleted_at: null, payload: { id: 'c1', n: 'remote' } }],
    next_cursor: 8, has_more: false, reset_required: false
  });
  assert.equal(applied.db.cust[0].n, 'remote');
  assert.equal(applied.state.cursor, 8);
  assert.equal(initialState.cursor, 0);
  assert.equal(initialDb.cust[0].n, 'local');

  const reset = applySyncPullPage(initialDb, initialState, {
    records: [], next_cursor: 0, has_more: true, reset_required: true
  });
  assert.equal(reset.resetRequired, true);
  assert.equal(reset.state.cursor, 0);
  assert.equal(reset.db, initialDb);

  assert.throws(() => applySyncPullPage(initialDb, initialState, {
    records: 'invalid', next_cursor: 1, has_more: false, reset_required: false
  }));
  assert.throws(() => applySyncPullPage(initialDb, { ...initialState, cursor: 9 }, {
    records: [], next_cursor: 8, has_more: false, reset_required: false
  }));
});

test('object-shaped advanced settings remain local and are not flattened or overwritten by pull', () => {
  const db = {
    advancedSettings: { warehouses: true, sms: { apiKey: 'local-secret' } },
    cust: [{ id: 'c1', n: 'local' }]
  };
  const prepared = prepareSyncOperations({ advancedSettings: db.advancedSettings }, createSyncState(), ids);
  assert.equal(prepared.operations.some(op => op.collection === 'advancedSettings'), false);
  const pulled = applyPulledRecords(db, createSyncState(), [
    { collection: 'cust', legacy_id: 'c2', version: 1, payload: { id: 'c2', n: 'remote' } },
    { collection: 'advancedSettings', legacy_id: 'settings', version: 1, payload: { warehouses: false } }
  ]);
  assert.deepEqual(pulled.db.advancedSettings, db.advancedSettings);
  assert.equal(pulled.db.cust.find(x => x.id === 'c2').n, 'remote');
});



test('durable checkpoint API rejects incomplete snapshots before opening storage', async () => {
  const { loadSyncCheckpoint, commitSyncCheckpoint, clearSyncCheckpoint } = await import('./sync-storage.js');
  await assert.rejects(() => loadSyncCheckpoint(''), /businessId is required/);
  await assert.rejects(() => clearSyncCheckpoint(''), /businessId is required/);
  await assert.rejects(() => commitSyncCheckpoint('b1', null, createSyncState()), /dbSnapshot must be a database object/);
  await assert.rejects(() => commitSyncCheckpoint('b1', {}, { cursor: -1 }), /syncState cursor is invalid/);
});


test('IndexedDB checkpoint transactions attach completion handlers before completion events', async () => {
  const { loadSyncCheckpoint, commitSyncCheckpoint, clearSyncCheckpoint } = await import('./sync-storage.js');
  const rows = new Map();
  const makeRequest = (result) => {
    const request = { result, error: null, onsuccess: null, onerror: null };
    setTimeout(() => request.onsuccess?.(), 0);
    return request;
  };
  const indexedDBImpl = {
    open() {
      const request = { result: null, error: null, onupgradeneeded: null, onsuccess: null, onerror: null, onblocked: null };
      const storeNames = { contains: () => true };
      const db = {
        objectStoreNames: storeNames,
        close() {},
        transaction() {
          const tx = {
            error: null, oncomplete: null, onabort: null, onerror: null,
            objectStore() {
              return {
                get(key) {
                  const request = { result: rows.get(key) ?? null, error: null, onsuccess: null, onerror: null };
                  setTimeout(() => { request.onsuccess?.(); tx.oncomplete?.(); }, 0);
                  return request;
                },
                put(value) { rows.set(value.businessId, value); setTimeout(() => tx.oncomplete?.(), 0); },
                delete(key) { rows.delete(key); queueMicrotask(() => tx.oncomplete?.()); }
              };
            }
          };
          return tx;
        }
      };
      request.result = db;
      setTimeout(() => request.onsuccess?.(), 0);
      return request;
    }
  };
  const snapshot = { cust: [{ id: 'c1', n: 'A' }] };
  const state = createSyncState();
  await commitSyncCheckpoint('business-1', snapshot, state, indexedDBImpl);
  const loaded = await loadSyncCheckpoint('business-1', indexedDBImpl);
  assert.deepEqual(loaded.db, snapshot);
  assert.equal(loaded.syncState.cursor, 0);
  await clearSyncCheckpoint('business-1', indexedDBImpl);
  assert.equal(await loadSyncCheckpoint('business-1', indexedDBImpl), null);
});


test('db:v2 adapter creates detached JSON snapshots without mutating the live database', async () => {
  const { createLocalDatabaseSnapshot, saveLocalDatabaseCheckpoint, loadLocalDatabaseCheckpoint } = await import('./sync-db-adapter.js');
  const live = {
    cust: [{ id: 'c1', n: 'Customer' }],
    advancedSettings: { sms: { apiKey: 'device-local-secret' } }
  };
  const snapshot = createLocalDatabaseSnapshot(live);
  assert.deepEqual(snapshot, live);
  assert.notEqual(snapshot, live);
  assert.notEqual(snapshot.cust, live.cust);
  snapshot.cust[0].n = 'changed snapshot';
  assert.equal(live.cust[0].n, 'Customer');
  await assert.rejects(() => saveLocalDatabaseCheckpoint({
    businessId: '', database: live, syncState: createSyncState()
  }), /explicitly selected business/);
  await assert.rejects(() => loadLocalDatabaseCheckpoint({ businessId: '' }), /explicitly selected business/);
  assert.throws(() => createLocalDatabaseSnapshot(null), /must be an object/);
});


test('legacy db:v2 adoption requires confirmation and never overwrites or deletes source data', async () => {
  const {
    LEGACY_DATABASE_KEY, LEGACY_ADOPTION_MARKER,
    loadBusinessDatabase, saveBusinessDatabase, adoptLegacyDatabaseForBusiness
  } = await import('./business-db-scope.js');
  const values = new Map([[LEGACY_DATABASE_KEY, JSON.stringify({
    cust: [{ id: 'legacy-1', n: 'Old customer' }],
    advancedSettings: { sms: { apiKey: 'local-only' } }
  })]]);
  const storage = {
    getItem(key) { return values.has(key) ? values.get(key) : null; },
    setItem(key, value) { values.set(key, String(value)); }
  };
  const declined = adoptLegacyDatabaseForBusiness({ storage, businessId: 'biz-A' });
  assert.equal(declined.adopted, false);
  assert.equal(declined.reason, 'confirmation_required');
  assert.equal(values.has('db:v2:business:biz-A'), false);

  const adopted = adoptLegacyDatabaseForBusiness({
    storage, businessId: 'biz-A', confirmed: true
  });
  assert.equal(adopted.adopted, true);
  assert.deepEqual(loadBusinessDatabase({ storage, businessId: 'biz-A' }), JSON.parse(values.get(LEGACY_DATABASE_KEY)));
  assert.ok(values.has(LEGACY_DATABASE_KEY), 'legacy source remains available as recovery copy');
  assert.ok(values.has(LEGACY_ADOPTION_MARKER));

  const secondBusiness = adoptLegacyDatabaseForBusiness({
    storage, businessId: 'biz-B', confirmed: true
  });
  assert.equal(secondBusiness.adopted, false);
  assert.equal(secondBusiness.reason, 'legacy_database_already_assigned');

  saveBusinessDatabase({
    storage, businessId: 'biz-B', database: { cust: [{ id: 'new', n: 'Separate' }] }
  });
  assert.deepEqual(loadBusinessDatabase({ storage, businessId: 'biz-B' }), {
    cust: [{ id: 'new', n: 'Separate' }]
  });
  assert.deepEqual(loadBusinessDatabase({ storage, businessId: 'biz-A' }), JSON.parse(values.get(LEGACY_DATABASE_KEY)));
  assert.throws(() => loadBusinessDatabase({ storage, businessId: '' }), /explicit business ID/);
});


test('business switch saves the previous business and never leaks its data into the next one', async () => {
  const { BUSINESS_DATABASE_PREFIX } = await import('./business-db-scope.js');
  const { switchLocalBusinessDatabase } = await import('./business-db-switch.js');
  const values = new Map();
  const storage = {
    getItem(key) { return values.has(key) ? values.get(key) : null; },
    setItem(key, value) { values.set(key, String(value)); }
  };
  const a = { cust: [{ id: 'a-customer', n: 'Business A' }] };
  const first = switchLocalBusinessDatabase({
    storage, currentBusinessId: '', nextBusinessId: 'biz-A',
    currentDatabase: {}, confirmLegacyAdoption: false
  });
  assert.equal(first.requiresEmptyDatabase, true);
  const second = switchLocalBusinessDatabase({
    storage, currentBusinessId: 'biz-A', nextBusinessId: 'biz-B',
    currentDatabase: a, confirmLegacyAdoption: false
  });
  assert.equal(second.businessId, 'biz-B');
  assert.equal(second.database, null);
  assert.equal(second.requiresEmptyDatabase, true);
  assert.deepEqual(JSON.parse(values.get(BUSINESS_DATABASE_PREFIX + 'biz-A')), a);

  const back = switchLocalBusinessDatabase({
    storage, currentBusinessId: 'biz-B', nextBusinessId: 'biz-A',
    currentDatabase: { cust: [{ id: 'b-customer', n: 'Business B' }] }
  });
  assert.deepEqual(back.database, a);
  assert.deepEqual(JSON.parse(values.get(BUSINESS_DATABASE_PREFIX + 'biz-B')), {
    cust: [{ id: 'b-customer', n: 'Business B' }]
  });
  const same = switchLocalBusinessDatabase({
    storage, currentBusinessId: 'biz-A', nextBusinessId: 'biz-A',
    currentDatabase: a
  });
  assert.equal(same.changed, false);
  assert.equal(same.database, a);
  assert.throws(() => switchLocalBusinessDatabase({
    storage, currentBusinessId: 'biz-A', nextBusinessId: '',
    currentDatabase: a
  }), /valid business/);
});


test('legacy adoption rolls back its claim if writing the business copy fails', async () => {
  const { LEGACY_DATABASE_KEY, LEGACY_ADOPTION_MARKER, adoptLegacyDatabaseForBusiness } =
    await import('./business-db-scope.js');
  const values = new Map([[LEGACY_DATABASE_KEY, JSON.stringify({ cust: [{ id: 'legacy' }] })]]);
  const storage = {
    getItem(key) { return values.has(key) ? values.get(key) : null; },
    setItem(key, value) {
      if (key === 'db:v2:business:biz-fail') throw new Error('quota exceeded');
      values.set(key, String(value));
    },
    removeItem(key) { values.delete(key); }
  };
  assert.throws(() => adoptLegacyDatabaseForBusiness({
    storage, businessId: 'biz-fail', confirmed: true
  }), /quota exceeded/);
  assert.equal(values.has(LEGACY_ADOPTION_MARKER), false);
  assert.equal(values.has(LEGACY_DATABASE_KEY), true);
  assert.equal(values.has('db:v2:business:biz-fail'), false);
});

test('legacy adoption leaves a fail-closed pending claim if rollback is unavailable', async () => {
  const { LEGACY_DATABASE_KEY, LEGACY_ADOPTION_MARKER, adoptLegacyDatabaseForBusiness } =
    await import('./business-db-scope.js');
  const values = new Map([[LEGACY_DATABASE_KEY, JSON.stringify({ cust: [] })]]);
  const storage = {
    getItem(key) { return values.has(key) ? values.get(key) : null; },
    setItem(key, value) {
      if (key === 'db:v2:business:biz-stuck') throw new Error('quota exceeded');
      values.set(key, String(value));
    }
  };
  assert.throws(() => adoptLegacyDatabaseForBusiness({
    storage, businessId: 'biz-stuck', confirmed: true
  }), /quota exceeded/);
  const marker = JSON.parse(values.get(LEGACY_ADOPTION_MARKER));
  assert.equal(marker.businessId, 'biz-stuck');
  assert.equal(marker.state, 'pending');
  const other = adoptLegacyDatabaseForBusiness({
    storage, businessId: 'biz-other', confirmed: true
  });
  assert.equal(other.adopted, false);
  assert.equal(other.reason, 'legacy_database_already_assigned');
});


test('startup resolver never attaches legacy db:v2 to a business without explicit consent', async () => {
  const { LEGACY_DATABASE_KEY, BUSINESS_DATABASE_PREFIX, saveBusinessDatabase } =
    await import('./business-db-scope.js');
  const { resolveInitialBusinessDatabase } = await import('./business-db-bootstrap.js');
  const values = new Map([[LEGACY_DATABASE_KEY, JSON.stringify({
    cust: [{ id: 'legacy-customer', n: 'Unassigned legacy data' }]
  })]]);
  const storage = {
    getItem(key) { return values.has(key) ? values.get(key) : null; },
    setItem(key, value) { values.set(key, String(value)); },
    removeItem(key) { values.delete(key); }
  };
  const noBusiness = resolveInitialBusinessDatabase({ storage, businessId: '' });
  assert.equal(noBusiness.status, 'no_business');
  assert.equal(noBusiness.legacyAvailable, true);

  const undecided = resolveInitialBusinessDatabase({ storage, businessId: 'biz-A' });
  assert.equal(undecided.status, 'needs_legacy_decision');
  assert.equal(undecided.database, null);
  assert.equal(values.has(BUSINESS_DATABASE_PREFIX + 'biz-A'), false);

  const adopted = resolveInitialBusinessDatabase({
    storage, businessId: 'biz-A', legacyAdoptionConfirmed: true
  });
  assert.equal(adopted.status, 'adopted');
  assert.equal(adopted.database.cust[0].id, 'legacy-customer');

  saveBusinessDatabase({
    storage, businessId: 'biz-B', database: { cust: [{ id: 'biz-b-only' }] }
  });
  const isolated = resolveInitialBusinessDatabase({ storage, businessId: 'biz-B' });
  assert.equal(isolated.status, 'loaded');
  assert.equal(isolated.database.cust[0].id, 'biz-b-only');
});


test('sync adapter creates detached JSON snapshots and requires an explicit business scope', async () => {
  const { createLocalDatabaseSnapshot, saveLocalDatabaseCheckpoint, loadLocalDatabaseCheckpoint } =
    await import('./sync-db-adapter.js');
  const source = { cust: [{ id: 'c1', name: 'Before' }], advancedSettings: { sms: { apiKey: 'local-only' } } };
  const snapshot = createLocalDatabaseSnapshot(source);
  source.cust[0].name = 'After';
  assert.equal(snapshot.cust[0].name, 'Before');
  assert.equal(snapshot.advancedSettings.sms.apiKey, 'local-only');
  assert.throws(() => createLocalDatabaseSnapshot([]), /database must be an object/);
  await assert.rejects(() => saveLocalDatabaseCheckpoint({
    businessId: '', database: snapshot, syncState: createSyncState()
  }), /explicitly selected business/);
  await assert.rejects(() => loadLocalDatabaseCheckpoint({ businessId: '' }), /explicitly selected business/);
});


test('cloud readiness probe covers every RPC used by the shared cloud client', async () => {
  const { readFile } = await import('node:fs/promises');
  const source = await readFile(new URL('./cloud-client.js', import.meta.url), 'utf8');
  const used = [...new Set([...source.matchAll(/client\.rpc\('([^']+)'/g)].map(match => match[1]))];
  const healthStart = source.indexOf('async getClientHealth');
  assert.notEqual(healthStart, -1, 'cloud readiness probe must exist');
  const healthSource = source.slice(healthStart);
  const checked = new Set([...healthSource.matchAll(/client\.rpc\('([^']+)'/g)].map(match => match[1]));
  assert.deepEqual(used.filter(name => !checked.has(name)), [],
    'every RPC used by the app must be checked before enabling shared cloud features');
});
