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

