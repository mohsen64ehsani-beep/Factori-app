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
  assert.deepEqual(operations.map(op => op.collection), ['cust', 'pay']);
});

test('financial records are staged as upserts and cannot use generic deletes', async () => {
  const { operations } = prepareSyncOperations({
    pay: [{ id: 'receipt-1', amt: 10 }],
    supplierPayments: [{ id: 'supplier-payment-1', amount: 20 }],
    expenses: [{ id: 'expense-1', amt: 5 }],
    otherincome: [{ id: 'income-1', amount: 3 }]
  }, createSyncState(), ids);
  assert.deepEqual(operations.map(op => op.collection), [
    'pay', 'supplierPayments', 'expenses', 'otherincome'
  ]);
  assert.ok(operations.every(op => op.operation_type === 'upsert'));
  const { createSyncTombstone } = await import('./sync-engine.js');
  const known = { ...createSyncState(), versions: { pay: { 'receipt-1': 1 } } };
  assert.throws(() => createSyncTombstone('pay', 'receipt-1', known));
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
    records: [], next_cursor: 0, has_more: true, reset_required: true,
    readable_collections: ['cust'], cost_access: true
  });
  assert.equal(reset.resetRequired, true);
  assert.equal(reset.state.cursor, 0);
  assert.deepEqual(reset.db.cust, initialDb.cust);
  assert.deepEqual(reset.db.prod, []);
  assert.notEqual(reset.db, initialDb);

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
  const baseSnapshot = { cust: [{ id: 'c1', n: 'Before remote pull' }] };
  await commitSyncCheckpoint('business-1', snapshot, state, indexedDBImpl, baseSnapshot);
  const loaded = await loadSyncCheckpoint('business-1', indexedDBImpl);
  assert.deepEqual(loaded.db, snapshot);
  assert.deepEqual(loaded.baseDb, baseSnapshot);
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


test('Premium entitlement follows the signed-in account and selected business, not the handset token', async () => {
  const { readFile } = await import('node:fs/promises');
  const app = await readFile(new URL('./index.html', import.meta.url), 'utf8');
  const cloud = await readFile(new URL('./cloud-client.js', import.meta.url), 'utf8');
  assert.match(app, /accountLicenseMode=false/);
  assert.match(app, /factoori:account-license-mode/);
  assert.match(app, /window\.FactooriCloud\.getEntitlements\(cloudActiveBusinessId\)/);
  assert.match(app, /active=entitlement\?\.is_premium===true&&entitlement\?\.plan_status==='premium'/);
  assert.match(app, /window\.FactooriCloud\.claimLicense\(cloudActiveBusinessId,code\)/);
  assert.match(app, /else if\(accountLicenseMode\)/);
  assert.match(app, /cloudBusinesses=\[\];cloudActiveBusinessId='';licenseActive=false/);
  assert.match(app, /licenseActive=false;cloudActiveBusinessId=id\|\|''/);
  assert.match(app, /await refreshLicenseStatus\(false\);render\(\);if\(id\)scheduleBusinessSync/);
  assert.match(cloud, /async claimLicense\(businessId, licenseKey\)/);
  assert.match(cloud, /client\.rpc\('claim_factori_license'/);
});


test('explicit deletions are queued for remote sync from supported business collections', async () => {
  const { readFile } = await import('node:fs/promises');
  const app = await readFile(new URL('./index.html', import.meta.url), 'utf8');
  const runtime = await readFile(new URL('./sync-runtime.js', import.meta.url), 'utf8');
  assert.match(runtime, /export async function recordBusinessDeletion/);
  assert.match(runtime, /createSyncTombstone\(collection, legacyId, checkpoint\.syncState\)/);
  assert.match(runtime, /flushDeferredBusinessDeletions\(businessId, indexedDBImpl\)/);
  assert.match(runtime, /recordBusinessDeletion\s*\n\s*\}\);/);
  for (const [collection, handler] of [
    ['cust', /db\.cust=db\.cust\.filter\(c=>c\.id!=id\);queueBusinessSyncDeletion\('cust',id\)/],
    ['prod', /db\.prod=db\.prod\.filter\(p=>p\.id!=id\);queueBusinessSyncDeletion\('prod',id\)/],
    ['inv', /db\.inv=db\.inv\.filter\(i=>i!==o\);queueBusinessSyncDeletion\('inv',id\)/],
    ['serviceInv', /db\.serviceInv=db\.serviceInv\.filter\(x=>x\.id!==id\);queueBusinessSyncDeletion\('serviceInv',id\)/],
    ['bankAccounts', /db\.bankAccounts=db\.bankAccounts\.filter\(x=>x\.id!==id\);queueBusinessSyncDeletion\('bankAccounts',id\)/]
  ]) assert.match(app, handler, collection + ' deletion must be explicitly queued');
});


test('cloud readiness distinguishes schema errors from transport failures', async () => {
  const { isSchemaProbeErrorReady } = await import('./cloud-health.js');
  assert.equal(isSchemaProbeErrorReady(null), true);
  assert.equal(isSchemaProbeErrorReady({ code: '42501' }), true);
  assert.equal(isSchemaProbeErrorReady({ code: '22P02' }), true);
  assert.equal(isSchemaProbeErrorReady({ code: 'PGRST116' }), true);
  assert.equal(isSchemaProbeErrorReady({ code: 'PGRST202' }), false);
  assert.equal(isSchemaProbeErrorReady({ message: 'Failed to fetch' }), false);
  assert.equal(isSchemaProbeErrorReady({ code: 'ECONNRESET' }), false);
  assert.equal(isSchemaProbeErrorReady({ code: 'FETCH_ERROR' }), false);
});


test('cloud startup always clears stale selection when schema readiness is false', async () => {
  const { readFile } = await import('node:fs/promises');
  const source = await readFile(new URL('./index.html', import.meta.url), 'utf8');
  assert.match(source, /cloudSchemaReady=await api\.getClientHealth\(\);await loadCloudBusinesses\(\)/);
  assert.match(source, /if\(!api\|\|!cloudSession\?\.user\?\.id\|\|!cloudSchemaReady\)\{\s*cloudBusinesses=\[\];\s*cloudActiveBusinessId='';\s*try\{localStorage\.removeItem\('factoori:active-business'\)/);
});


test('cloud client RPC argument names exist in the checked-in SQL contracts', async () => {
  const { readFile, readdir } = await import('node:fs/promises');
  const client = await readFile(new URL('./cloud-client.js', import.meta.url), 'utf8');
  const draftFiles = await readdir(new URL('./supabase/drafts/', import.meta.url));
  const sql = (await Promise.all(draftFiles.filter(name => name.endsWith('.sql'))
    .map(name => readFile(new URL('./supabase/drafts/' + name, import.meta.url), 'utf8')))).join('\\n');
  const used = new Map();
  for (const match of client.matchAll(/client\.rpc\('([^']+)'/g)) {
    const name = match[1];
    const start = client.indexOf('{', match.index + match[0].length);
    if (start < 0) continue;
    let depth = 0, end = -1, quote = '';
    for (let i = start; i < client.length; i++) {
      const ch = client[i];
      if (quote) { if (ch === quote && client[i - 1] !== '\\') quote = ''; continue; }
      if (ch === "'" || ch === '"' || ch === '`') { quote = ch; continue; }
      if (ch === '{') depth++;
      if (ch === '}' && --depth === 0) { end = i; break; }
    }
    if (end < 0) continue;
    const keys = [...client.slice(start, end + 1).matchAll(/\b(p_[a-z0-9_]+)\s*:/g)].map(item => item[1]);
    if (!used.has(name)) used.set(name, new Set());
    keys.forEach(key => used.get(name).add(key));
  }
  for (const [name, keys] of used) {
    const signature = sql.match(new RegExp('create\\s+or\\s+replace\\s+function\\s+public\\.' + name + '\\s*\\(([\\s\\S]*?)\\)\\s*returns', 'i'));
    assert.ok(signature, 'SQL function is missing: ' + name);
    const accepted = new Set([...signature[1].matchAll(/\b(p_[a-z0-9_]+)\s+[a-z]/gi)].map(item => item[1]));
    assert.deepEqual([...keys].filter(key => !accepted.has(key)), [], 'unknown RPC args for ' + name);
  }
});


test('permission-version reset redacts stale private cache and quarantines pending payloads', async () => {
  const { applySyncPullPage } = await import('./sync-engine.js');
  const db = {
    prod: [{ id: 'p1', n: 'محصول', buy: 120, averageCost: 90, nested: [{ profit: 30, qty: 2 }] }],
    inv: [{ id: 'i1', items: [{ name: 'x', costTotal: 500, price: 900 }], profitAmount: 400 }],
    advancedSettings: { sms: { apiKey: 'LOCAL-SECRET' } }
  };
  const state = {
    ...createSyncState(),
    cursor: 81,
    versions: { prod: { p1: 3 } },
    snapshots: { prod: { p1: JSON.stringify({ id: 'p1', n: 'محصول', buy: 120 }) } },
    pending: [{ operation_id: 'pending-secret', collection: 'prod', legacy_id: 'p1',
      operation_type: 'upsert', base_version: 3, payload: { id: 'p1', buy: 150, price: 200 } }],
    conflicts: [{ remote_record: { collection: 'prod', payload: { id: 'p1', cost: 70 } } }],
    rejected: [{ operation: { payload: { id: 'p1', profit: 50 } } }]
  };
  const result = applySyncPullPage(db, state, { reset_required: true, readable_collections: ['prod', 'inv'], cost_access: false });
  assert.equal(result.resetRequired, true);
  assert.equal(result.state.cursor, 0);
  assert.equal(result.db.prod[0].buy, undefined);
  assert.equal(result.db.prod[0].averageCost, undefined);
  assert.equal(result.db.prod[0].nested[0].profit, undefined);
  assert.equal(result.db.inv[0].items[0].costTotal, undefined);
  assert.equal(result.db.inv[0].items[0].price, 900);
  assert.equal(result.db.inv[0].profitAmount, undefined);
  assert.equal(result.db.advancedSettings.sms.apiKey, 'LOCAL-SECRET');
  assert.equal(result.state.pending.length, 0);
  assert.equal(result.state.conflicts.at(-1).reason, 'permission_version_changed');
  assert.equal(result.state.conflicts.at(-1).operation.payload.buy, undefined);
  assert.equal(result.state.conflicts[0].remote_record.payload.cost, undefined);
  assert.equal(result.state.rejected[0].operation.payload.profit, undefined);
  assert.equal(JSON.parse(result.state.snapshots.prod.p1).buy, undefined);
  assert.equal(state.cursor, 81, 'reset must not mutate the input sync state');
  assert.equal(db.prod[0].buy, 120, 'reset must not mutate the live database');

  const unsynced = applySyncPullPage(
    { prod: [{ id: 'p2', name: 'edited locally', buy: 30 }] },
    {
      ...createSyncState(),
      versions: { prod: { p2: 1 } },
      snapshots: { prod: { p2: JSON.stringify({ buy: 20, id: 'p2', name: 'old name' }) } },
      pending: [{ operation_id: 'pending-public-edit', collection: 'prod', legacy_id: 'p2',
        operation_type: 'upsert', base_version: 1,
        payload: { id: 'p2', name: 'edited locally', buy: 30 } }]
    },
    { reset_required: true, readable_collections: ['prod'], cost_access: false }
  );
  const replayed = applySyncPullPage(unsynced.db, unsynced.state, {
    records: [{ collection: 'prod', legacy_id: 'p2', version: 2, revision: 1,
      change_type: 'upsert', deleted_at: null, payload: { id: 'p2', name: 'remote version' } }],
    next_cursor: 1, has_more: false, reset_required: false
  });
  assert.equal(replayed.db.prod[0].name, 'edited locally',
    'full permission-reset pull must not overwrite a locally dirty row');
  const retry = prepareSyncOperations(replayed.db, replayed.state, ids);
  assert.equal(retry.operations.length, 1, 'public edits must remain eligible for retry after permission reset');
  assert.deepEqual(retry.operations[0].payload, { id: 'p2', name: 'edited locally' });
  assert.equal(retry.state.permissionResetDirty.length, 0, 'the new pending operation replaces the reset dirty marker');
});


test('local sync collection allowlists exactly match SQL read and write permissions', async () => {
  const { readFile } = await import('node:fs/promises');
  const { SYNC_READ_COLLECTIONS, SYNC_WRITE_COLLECTIONS } = await import('./sync-engine.js');
  const sql = await readFile(new URL('./supabase/drafts/005_sync_compatibility.sql', import.meta.url), 'utf8');
  const readStart = sql.indexOf("if p_operation='read' then");
  const writeStart = sql.indexOf("elsif p_operation in ('write','delete') then");
  const writeEnd = sql.indexOf("else\n    return false;", writeStart);
  assert.ok(readStart >= 0 && writeStart > readStart && writeEnd > writeStart);
  const readSection = sql.slice(readStart, writeStart);
  const writeSection = sql.slice(writeStart, writeEnd);
  const sqlRead = [...readSection.matchAll(/when '([^']+)' then '([^']+)'/g)].map(match => match[1]).sort();
  const sqlWrite = [...writeSection.matchAll(/when '([^']+)' then '([^']+)'/g)].map(match => match[1]).sort();
  assert.deepEqual([...SYNC_READ_COLLECTIONS].sort(), sqlRead);
  assert.deepEqual([...SYNC_WRITE_COLLECTIONS].sort(), sqlWrite);
});


test('permission changes advance member version so sync clients receive a reset', async () => {
  const { readFile } = await import('node:fs/promises');
  const migration = await readFile(new URL('./supabase/drafts/004a_sync_infrastructure.sql', import.meta.url), 'utf8');
  const syncSql = await readFile(new URL('./supabase/drafts/005_sync_compatibility.sql', import.meta.url), 'utf8');
  assert.match(migration, /new\.role_code is distinct from old\.role_code or new\.status is distinct from old\.status[\s\S]*new\.permission_version:=old\.permission_version\+1/);
  assert.match(migration, /after insert or update or delete on public\.business_member_permission_overrides[\s\S]*execute function private\.bump_override_permission_version/);
  assert.match(syncSql, /v_device\.permission_version<>v_member_permission_version[\s\S]*'reset_required',true/);
});


test('local permission-reset redaction keys exactly match SQL private payload keys', async () => {
  const { readFile } = await import('node:fs/promises');
  const { SYNC_SENSITIVE_FIELDS } = await import('./sync-engine.js');
  const sql = await readFile(new URL('./supabase/drafts/005_sync_compatibility.sql', import.meta.url), 'utf8');
  const start = sql.indexOf('where e.key not in (', sql.indexOf('create or replace function private.strip_sensitive_json'));
  const end = sql.indexOf(');', start);
  assert.ok(start >= 0 && end > start);
  const sqlFields = [...sql.slice(start, end).matchAll(/'([^']+)'/g)].map(match => match[1]).sort();
  assert.deepEqual([...SYNC_SENSITIVE_FIELDS].sort(), sqlFields);
});


test('cloud account switch isolates data and membership lookup failures preserve active local data', async () => {
  const { readFile } = await import('node:fs/promises');
  const source = await readFile(new URL('./index.html', import.meta.url), 'utf8');
  assert.match(source, /if\(accountChanged\)\{\s*cloudBusinesses=\[\];cloudActiveBusinessId='';licenseActive=false;\s*try\{localStorage\.removeItem\('factoori:active-business'\)\}catch\(e\)\{\}\s*try\{isolateLocalDataForCloudSession\(\)\}\s*catch\(e\)\{cloudSession=null;cloudSchemaReady=false;throw e\}/);
  assert.match(source, /catch\(error\)\{\s*\/\/ A failed membership request is not proof that the user has no businesses\.[\s\S]*?throw error;\s*\}/);
  assert.doesNotMatch(source, /catch\(error\)\{\s*cloudBusinesses=\[\];cloudActiveBusinessId='';[\s\S]*?resetCloudBusinessContext\(\)/);
  assert.match(source, /function isolateLocalDataForCloudSession\(\)[\s\S]*?localDbBusinessId='';[\s\S]*?businessScopedMode=true;db=JSON\.parse\(EMPTY_BUSINESS_DB_JSON\)/);
  assert.match(source, /function resetCloudBusinessContext\(\)[\s\S]*?cloudSession=null;cloudSchemaReady=false;cancelBusinessSync\(\);return false/);
  assert.match(source, /\}else if\(!demoMode\)\{\s*resetCloudBusinessContext\(\);\s*\}/);

});


test('permission reset clears unreadable collections but retains permitted private data', async () => {
  const { applySyncPullPage } = await import('./sync-engine.js');
  const db = {
    cust: [{ id: 'c1', n: 'مشتری محروم' }],
    prod: [{ id: 'p1', n: 'محصول', buy: 120 }],
    advancedSettings: { sms: { apiKey: 'KEEP-LOCAL' } }
  };
  const state = {
    ...createSyncState(),
    versions: { cust: { c1: 2 }, prod: { p1: 3 } },
    snapshots: { cust: { c1: '{"id":"c1","n":"مشتری محروم"}' }, prod: { p1: '{"buy":120,"id":"p1","n":"محصول"}' } },
    pending: [
      { operation_id: 'cust-op', collection: 'cust', legacy_id: 'c1', operation_type: 'upsert', payload: { id: 'c1', n: 'مشتری محروم' } },
      { operation_id: 'prod-op', collection: 'prod', legacy_id: 'p1', operation_type: 'upsert', payload: { id: 'p1', n: 'محصول', buy: 120 } }
    ]
  };
  const result = applySyncPullPage(db, state, {
    reset_required: true, readable_collections: ['prod'], cost_access: true
  });
  assert.deepEqual(result.db.cust, []);
  assert.equal(result.db.prod[0].buy, 120);
  assert.equal(result.db.advancedSettings.sms.apiKey, 'KEEP-LOCAL');
  assert.equal(result.state.pending.length, 1);
  assert.equal(result.state.pending[0].collection, 'prod');
  assert.equal(result.state.conflicts.at(-1).reason, 'read_permission_revoked');
  assert.equal(result.state.conflicts.at(-1).operation_id, 'cust-op');
  assert.equal(result.state.versions.cust, undefined);
  assert.equal(result.state.snapshots.cust, undefined);
  assert.equal(state.pending.length, 2, 'permission reset must not mutate input state');
});


test('permission reset without access metadata clears shared collections fail-closed', async () => {
  const { applySyncPullPage } = await import('./sync-engine.js');
  const result = applySyncPullPage(
    { cust: [{ id: 'c1', n: 'stale' }], prod: [{ id: 'p1', n: 'stale' }] },
    createSyncState(),
    { reset_required: true }
  );
  assert.deepEqual(result.db.cust, []);
  assert.deepEqual(result.db.prod, []);
});


test('SQL permission reset returns the readable collection and cost-access snapshot', async () => {
  const { readFile } = await import('node:fs/promises');
  const sql = await readFile(new URL('./supabase/drafts/005_sync_compatibility.sql', import.meta.url), 'utf8');
  const pull = sql.slice(sql.indexOf('create or replace function private.sync_pull'));
  const reset = pull.slice(pull.indexOf('if v_device.permission_version<>v_member_permission_version then'),
    pull.indexOf('v_cost_allowed:=(select private.has_business_permission'));
  assert.match(reset, /'readable_collections'/);
  assert.match(reset, /'cost_access'/);
  assert.match(reset, /private\.can_sync_collection\(p_business_id,c\.collection,'read'\)/);
  const { SYNC_READ_COLLECTIONS } = await import('./sync-engine.js');
  const arrayStart = reset.indexOf('unnest(array[');
  const arrayEnd = reset.indexOf(']) as c(collection)', arrayStart);
  assert.ok(arrayStart >= 0 && arrayEnd > arrayStart);
  const resetCollections = [...reset.slice(arrayStart, arrayEnd).matchAll(/'([^']+)'/g)].map(match => match[1]).sort();
  assert.deepEqual(resetCollections, [...SYNC_READ_COLLECTIONS].sort());
});


test('permission-reset pull refreshes base version when remote still matches prior snapshot', async () => {
  const { applySyncPullPage } = await import('./sync-engine.js');
  const localDb = { prod: [{ id: 'p1', n: 'local edit', buy: 10 }] };
  const state = {
    ...createSyncState(),
    versions: { prod: { p1: 1 } },
    snapshots: { prod: { p1: '{"id":"p1","n":"old"}' } },
    pending: [{ operation_id: 'pending', collection: 'prod', legacy_id: 'p1',
      operation_type: 'upsert', base_version: 1, payload: { id: 'p1', n: 'local edit', buy: 10 } }]
  };
  const reset = applySyncPullPage(localDb, state, {
    reset_required: true, readable_collections: ['prod'], cost_access: false
  });
  const pulled = applySyncPullPage(reset.db, reset.state, {
    records: [{ collection: 'prod', legacy_id: 'p1', version: 2, revision: 2,
      change_type: 'upsert', deleted_at: null, payload: { id: 'p1', n: 'old' } }],
    next_cursor: 2, has_more: false, reset_required: false
  });
  assert.equal(pulled.db.prod[0].n, 'local edit');
  assert.equal(pulled.state.versions.prod.p1, 2);
  const retry = prepareSyncOperations(pulled.db, pulled.state, ids);
  assert.equal(retry.operations[0].base_version, 2);
});


test('permission-reset pull recognizes an operation already applied remotely', async () => {
  const { applySyncPullPage } = await import('./sync-engine.js');
  const localDb = { prod: [{ id: 'p1', n: 'same edit', buy: 10 }] };
  const state = {
    ...createSyncState(),
    versions: { prod: { p1: 1 } },
    snapshots: { prod: { p1: '{"id":"p1","n":"old"}' } },
    pending: [{ operation_id: 'pending', collection: 'prod', legacy_id: 'p1',
      operation_type: 'upsert', base_version: 1, payload: { id: 'p1', n: 'same edit', buy: 10 } }]
  };
  const reset = applySyncPullPage(localDb, state, {
    reset_required: true, readable_collections: ['prod'], cost_access: false
  });
  const pulled = applySyncPullPage(reset.db, reset.state, {
    records: [{ collection: 'prod', legacy_id: 'p1', version: 2, revision: 2,
      change_type: 'upsert', deleted_at: null, payload: { id: 'p1', n: 'same edit' } }],
    next_cursor: 2, has_more: false, reset_required: false
  });
  assert.equal(pulled.state.versions.prod.p1, 2);
  assert.equal(pulled.state.permissionResetDirty.length, 0);
  assert.equal(prepareSyncOperations(pulled.db, pulled.state, ids).operations.length, 0);
});


test('business sync coordinator checkpoints pending IDs before push and persists pull pages', async () => {
  const { runBusinessSync } = await import('./sync-runtime.js');
  const checkpoints = [], calls = [];
  const api = {
    ensureSyncDevice: async () => ({ verified: true, device_id: 'device-1' }),
    getSyncDeviceId: () => 'device-1',
    syncPushBatches: async ({ operations }) => {
      calls.push(['push', operations.map(op => op.operation_id)]);
      return operations.map(op => ({ operation_id: op.operation_id, status: 'applied', version: 1 }));
    },
    syncPull: async ({ sinceRevision }) => {
      calls.push(['pull', sinceRevision]);
      return {
        records: [{ collection: 'cust', legacy_id: 'c1', version: 1, revision: 1,
          change_type: 'upsert', deleted_at: null, payload: { id: 'c1', n: 'مشتری' } }],
        next_cursor: 1, has_more: false, reset_required: false
      };
    }
  };
  const result = await runBusinessSync({
    businessId: 'business-1',
    database: { cust: [{ id: 'c1', n: 'مشتری' }] },
    syncState: createSyncState(),
    api,
    createOperationId: () => 'operation-1',
    persistCheckpoint: async checkpoint => checkpoints.push({
      businessId: checkpoint.businessId,
      pending: checkpoint.syncState.pending.length,
      cursor: checkpoint.syncState.cursor
    })
  });
  assert.equal(result.deviceId, 'device-1');
  assert.equal(result.syncState.cursor, 1);
  assert.equal(result.syncState.pending.length, 0);
  assert.equal(result.database.cust[0].n, 'مشتری');
  assert.equal(checkpoints[0].pending, 1, 'pending operation identity must be durable before network push');
  assert.ok(checkpoints.length >= 3, 'checkpoint should be committed before push, after acknowledgement, and after pull');
  assert.deepEqual(calls.map(call => call[0]), ['push', 'pull']);
});


test('business sync coordinator recovers from permission-version mismatch before retrying writes', async () => {
  const { runBusinessSync } = await import('./sync-runtime.js');
  const checkpoints = [];
  let pushCount = 0, pullCount = 0;
  const api = {
    ensureSyncDevice: async () => ({ verified: true, device_id: 'device-2' }),
    getSyncDeviceId: () => 'device-2',
    syncPushBatches: async ({ operations }) => {
      pushCount++;
      if (pushCount === 1) throw Object.assign(new Error('sync_permissions_changed'), { code: '42501' });
      return operations.map(op => ({ operation_id: op.operation_id, status: 'applied', version: 3 }));
    },
    syncPull: async ({ sinceRevision }) => {
      pullCount++;
      if (pullCount === 1) return {
        records: [], next_cursor: 0, has_more: true, reset_required: true,
        readable_collections: ['prod'], cost_access: false
      };
      if (pullCount === 2) return {
        records: [{ collection: 'prod', legacy_id: 'p1', version: 2, revision: 2,
          change_type: 'upsert', deleted_at: null, payload: { id: 'p1', n: 'old' } }],
        next_cursor: 2, has_more: false, reset_required: false
      };
      return {
        records: [{ collection: 'prod', legacy_id: 'p1', version: 3, revision: 3,
          change_type: 'upsert', deleted_at: null, payload: { id: 'p1', n: 'local edit' } }],
        next_cursor: 3, has_more: false, reset_required: false
      };
    }
  };
  const result = await runBusinessSync({
    businessId: 'business-2',
    database: { prod: [{ id: 'p1', n: 'local edit', buy: 10 }] },
    syncState: {
      ...createSyncState(),
      versions: { prod: { p1: 1 } },
      snapshots: { prod: { p1: '{"id":"p1","n":"old"}' } },
      pending: [{ operation_id: 'old-operation', collection: 'prod', legacy_id: 'p1',
        operation_type: 'upsert', base_version: 1, payload: { id: 'p1', n: 'local edit', buy: 10 } }]
    },
    api,
    createOperationId: () => 'retry-operation',
    persistCheckpoint: async checkpoint => checkpoints.push(checkpoint.syncState.cursor)
  });
  assert.equal(pushCount, 2);
  assert.equal(pullCount, 3);
  assert.equal(result.permissionResets, 1);
  assert.equal(result.database.prod[0].n, 'local edit');
  assert.equal(result.database.prod[0].buy, undefined, 'lost cost access must remove stale local cost data');
  assert.equal(result.syncState.pending.length, 0);
  assert.equal(result.syncState.cursor, 3);
  assert.ok(checkpoints.length >= 6);
});


test('regained cost access restores private fields without overwriting local public edits', async () => {
  const { applySyncPullPage } = await import('./sync-engine.js');
  const db = { prod: [{ id: 'p1', n: 'local edit' }] };
  const state = {
    ...createSyncState(),
    cursor: 0,
    versions: { prod: { p1: 2 } },
    snapshots: { prod: { p1: '{"id":"p1","n":"old"}' } },
    permissionResetDirty: [{ collection: 'prod', legacy_id: 'p1' }],
    permissionResetCostAccess: false
  };
  const reset = applySyncPullPage(db, state, {
    reset_required: true, readable_collections: ['prod'], cost_access: true
  });
  assert.equal(reset.state.permissionResetCostAccess, true);
  assert.equal(reset.state.permissionResetDirty.length, 1);
  const pulled = applySyncPullPage(reset.db, reset.state, {
    records: [{ collection: 'prod', legacy_id: 'p1', version: 3, revision: 3,
      change_type: 'upsert', deleted_at: null, payload: { id: 'p1', n: 'old', buy: 120 } }],
    next_cursor: 3, has_more: false, reset_required: false
  });
  assert.equal(pulled.db.prod[0].n, 'local edit');
  assert.equal(pulled.db.prod[0].buy, 120, 'private data is restored from the server after access is granted');
  assert.equal(pulled.state.versions.prod.p1, 3);
  const retry = prepareSyncOperations(pulled.db, pulled.state, ids);
  assert.equal(retry.operations[0].base_version, 3);
  assert.equal(retry.operations[0].payload.buy, 120);
});


test('business sync coordinator resumes a permission reset before any write retry', async () => {
  const { runBusinessSync } = await import('./sync-runtime.js');
  let pushCount = 0, pullCount = 0;
  const api = {
    ensureSyncDevice: async () => ({ verified: true, device_id: 'device-resume' }),
    getSyncDeviceId: () => 'device-resume',
    syncPushBatches: async ({ operations }) => {
      pushCount++;
      return operations.map(op => ({ operation_id: op.operation_id, status: 'applied', version: 2 }));
    },
    syncPull: async () => {
      pullCount++;
      return {
        records: [], next_cursor: pullCount, has_more: pullCount === 1, reset_required: false
      };
    }
  };
  const first = await runBusinessSync({
    businessId: 'business-resume',
    database: { prod: [{ id: 'p1', n: 'queued' }] },
    syncState: {
      ...createSyncState(),
      permissionResetInProgress: true,
      pending: [{ operation_id: 'queued-op', collection: 'prod', legacy_id: 'p1',
        operation_type: 'upsert', base_version: 1, payload: { id: 'p1', n: 'queued' } }]
    },
    api,
    createOperationId: () => 'next-op',
    maxPullPages: 1,
    persistCheckpoint: async () => {}
  });
  assert.equal(pushCount, 0, 'writes must wait until the permission reset pull is complete');
  assert.equal(first.hasMore, true);
  assert.equal(first.syncState.permissionResetInProgress, true);

  const second = await runBusinessSync({
    businessId: 'business-resume',
    database: first.database,
    syncState: first.syncState,
    api,
    createOperationId: () => 'next-op',
    maxPullPages: 5,
    persistCheckpoint: async () => {}
  });
  assert.equal(pushCount, 1);
  assert.equal(second.syncState.permissionResetInProgress, false);
  assert.equal(second.syncState.pending.length, 0);
});


test('app wires guarded sync scheduling to the runtime and rejects stale results', async () => {
  const { readFile } = await import('node:fs/promises');
  const html = await readFile(new URL('./index.html', import.meta.url), 'utf8');
  const runtime = await readFile(new URL('./sync-runtime.js', import.meta.url), 'utf8');
  assert.match(html, /<script type="module" src="sync-runtime\.js"><\/script>/);
  assert.match(html, /function scheduleBusinessSync\(delay=1100\)[\s\S]*?if\(demoMode\|\|!cloudSession\?\.user\?\.id\|\|!cloudSchemaReady\|\|!localDbBusinessId\)return/);
  assert.match(html, /localStorage\.setItem\(localDbBusinessId\?BUSINESS_DB_PREFIX\+localDbBusinessId:K,JSON\.stringify\(db\)\);dbRevision\+\+;scheduleBusinessSync\(\)/);
  assert.match(html, /localDbBusinessId===businessId&&syncGeneration===generation&&dbRevision===revision/);
  assert.match(html, /await window\.FactooriSyncRuntime\.acknowledgeBusinessDatabaseApplied\?\./);
  assert.match(html, /cloudSyncNow:\(\)=>/);
  assert.match(runtime, /window\.FactooriSyncRuntime = Object\.freeze/);
  assert.match(runtime, /factoori-sync-runtime-ready/);
});


test('business sync lock is released when checkpoint initialization fails', async () => {
  const { runBusinessSync } = await import('./sync-runtime.js');
  const api = {
    ensureSyncDevice: async () => ({ verified: true, device_id: 'device-lock-test' }),
    getSyncDeviceId: () => 'device-lock-test',
    syncPushBatches: async () => [],
    syncPull: async () => ({ records: [], next_cursor: 0, has_more: false, reset_required: false })
  };
  const options = {
    businessId: 'business-checkpoint-failure',
    database: { cust: [] },
    api,
    indexedDBImpl: { open() { throw new Error('IndexedDB unavailable in test'); } }
  };
  await assert.rejects(runBusinessSync(options), /IndexedDB unavailable in test/);
  await assert.rejects(runBusinessSync(options), /IndexedDB unavailable in test/);
});


test('checkpoint recovery restores pulled records and overlays only local edits made during the interrupted run', async () => {
  const { mergeLocalChangesOntoCheckpoint } = await import('./sync-db-adapter.js');
  const baseDatabase = {
    cust: [{ id: 'c1', n: 'old' }, { id: 'c2', n: 'to be deleted' }],
    prod: [{ id: 'p1', n: 'unchanged' }],
    advancedSettings: { sms: { apiKey: 'OLD-LOCAL' } }
  };
  const localDatabase = {
    cust: [{ id: 'c1', n: 'edited while sync ran' }],
    prod: [{ id: 'p1', n: 'unchanged' }],
    advancedSettings: { sms: { apiKey: 'NEW-LOCAL' } }
  };
  const checkpointDatabase = {
    cust: [{ id: 'c1', n: 'remote update' }, { id: 'c2', n: 'to be deleted' }, { id: 'c3', n: 'remote new' }],
    prod: [{ id: 'p1', n: 'remote unchanged' }],
    advancedSettings: { sms: { apiKey: 'OLD-LOCAL' } }
  };
  const merged = mergeLocalChangesOntoCheckpoint({ localDatabase, baseDatabase, checkpointDatabase });
  assert.deepEqual(merged.cust, [
    { id: 'c1', n: 'edited while sync ran' },
    { id: 'c3', n: 'remote new' }
  ]);
  assert.deepEqual(merged.prod, [{ id: 'p1', n: 'remote unchanged' }]);
  assert.equal(merged.advancedSettings.sms.apiKey, 'NEW-LOCAL');
  const noIdMerge = mergeLocalChangesOntoCheckpoint({
    baseDatabase: { services: ['cut', 'wash', 'cut'] },
    localDatabase: { services: ['cut', 'local-service', 'wash', 'cut'] },
    checkpointDatabase: { services: ['cut', 'wash', 'remote-service', 'cut'] }
  });
  assert.deepEqual(noIdMerge.services, ['cut', 'local-service', 'wash', 'cut'],
    'collections without stable IDs must preserve the complete local list, including duplicate values');
});


test('account isolation and logout preserve the active database when local persistence fails', async () => {
  const { readFile } = await import('node:fs/promises');
  const html = await readFile(new URL('./index.html', import.meta.url), 'utf8');
  const isolate = html.match(/function isolateLocalDataForCloudSession\(\)\{[\s\S]*?\n\}/)?.[0] || '';
  const restore = html.match(/function restoreLocalDataAfterCloudSession\(saveCurrentBusiness=true\)\{[\s\S]*?\n\}/)?.[0] || '';
  assert.ok(isolate.indexOf('throw new Error') < isolate.indexOf("localDbBusinessId=''"), 'failed save must abort before clearing the active business id');
  assert.match(restore, /catch\(e\)\{[\s\S]*?cloudSession=null;cloudSchemaReady=false;return false/);
  assert.ok(restore.indexOf('return false') < restore.indexOf("localDbBusinessId=''"), 'failed logout persistence must preserve the active local database');
  assert.match(html, /const initialSession=await api\.getSession\(\);[\s\S]*?isolateLocalDataForCloudSession\(\);\s*cloudSession=initialSession/);
});


test('splash routes through full-screen shared account auth and logout returns to auth gate', async () => {
  const { readFile } = await import('node:fs/promises');
  const app = await readFile(new URL('./index.html', import.meta.url), 'utf8');
  assert.match(app, /if\(lk=='auth'\)return/);
  assert.match(app, /lk='auth';lock=true/);
  assert.match(app, /cloudContinue:async/);
  assert.match(app, /lock=true;lk='auth';cloudAuthMode='login'/);
  assert.match(app, /cloudRegister/);
});

test('employee management is wired to a server-side provisioning function', async () => {
  const { readFile } = await import('node:fs/promises');
  const app = await readFile(new URL('./index.html', import.meta.url), 'utf8');
  const ui = await readFile(new URL('./member-management-ui.js', import.meta.url), 'utf8');
  const cloud = await readFile(new URL('./cloud-client.js', import.meta.url), 'utf8');
  const edge = await readFile(new URL('./supabase/functions/manage-business-members/index.ts', import.meta.url), 'utf8');
  const migration = await readFile(new URL('./supabase/drafts/011_employee_provisioning.sql', import.meta.url), 'utf8');
  assert.match(app, /cloudMemberCreate:async/);
  assert.match(ui, /memberPassword/);
  assert.match(ui, /data-member-perm/);
  assert.match(cloud, /manageBusinessMembers\(payload\)/);
  assert.match(edge, /auth\.admin\.createUser/);
  assert.match(edge, /provision_business_member/);
  assert.match(migration, /role_code in \('owner','admin','accountant','sales','viewer','warehouse'\)/);
});


test('client and server keep financial and stock mutations out of generic sync', async () => {
  const { SYNC_WRITE_COLLECTIONS } = await import('./sync-engine.js');
  const { readFile } = await import('node:fs/promises');
  const sql = await readFile(new URL('./supabase/drafts/005_sync_compatibility.sql', import.meta.url), 'utf8');
  const start = sql.indexOf('create or replace function private.can_sync_collection');
  const end = sql.indexOf('create or replace function private.register_sync_device', start);
  assert.ok(start >= 0 && end > start, 'server collection permission function must exist');
  const permissions = sql.slice(start, end);
  const blocked = [
    'debt','returns','pay','creditors','purchases','supplierPayments','creditorPayments',
    'expenses','otherincome','wastage','stockMoves','warehouseStocks','transfers',
    'accounts','moneytransfers','opening'
  ];
  for (const collection of blocked) {
    assert.ok(!SYNC_WRITE_COLLECTIONS.includes(collection), collection + ' must not be client write-enabled');
    assert.match(permissions, new RegExp("when '" + collection + "' then null"),
      collection + ' must remain blocked by server authorization');
  }
  for (const collection of ['cust','suppliers','duedates','prod','services','categories','inv','serviceInv','warehouses','bankAccounts','fiscal','smsHistory']) {
    assert.ok(SYNC_WRITE_COLLECTIONS.includes(collection), collection + ' is an explicitly enabled safe/draft sync collection');
    assert.match(permissions, new RegExp("when '" + collection + "' then '"));
  }
});
