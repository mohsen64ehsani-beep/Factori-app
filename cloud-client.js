import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = 'https://rtlwztotaolbnjdtsjqy.supabase.co';
const SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_GhG0h_Mco3UomLqxnhynnw_blPQ3ii-';

const client = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
  auth: {
    storage: window.localStorage,
    storageKey: 'factoori-auth-v1',
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: false,
    flowType: 'pkce'
  },
  global: {
    headers: { 'X-Client-Info': 'factoori-android-web/1' }
  }
});

function unwrap(result) {
  if (result?.error) throw result.error;
  return result?.data;
}

const DEVICE_KEY_DB = 'factoori-device-keys-v1';
const DEVICE_KEY_STORE = 'keys';

function openDeviceKeyStore() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DEVICE_KEY_DB, 1);
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains(DEVICE_KEY_STORE)) {
        request.result.createObjectStore(DEVICE_KEY_STORE, { keyPath: 'deviceId' });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error || new Error('ذخیره‌سازی امن کلید دستگاه در دسترس نیست.'));
  });
}

async function saveDevicePrivateKey(deviceId, businessId, privateKey) {
  const db = await openDeviceKeyStore();
  try {
    await new Promise((resolve, reject) => {
      const tx = db.transaction(DEVICE_KEY_STORE, 'readwrite');
      tx.objectStore(DEVICE_KEY_STORE).put({ deviceId, businessId, privateKey, savedAt: Date.now() });
      tx.oncomplete = resolve;
      tx.onerror = () => reject(tx.error);
      tx.onabort = () => reject(tx.error || new Error('ذخیره کلید دستگاه انجام نشد.'));
    });
  } finally { db.close(); }
}

async function getDevicePrivateKey(deviceId) {
  const db = await openDeviceKeyStore();
  try {
    return await new Promise((resolve, reject) => {
      const tx = db.transaction(DEVICE_KEY_STORE, 'readonly');
      const request = tx.objectStore(DEVICE_KEY_STORE).get(deviceId);
      request.onsuccess = () => resolve(request.result?.privateKey || null);
      request.onerror = () => reject(request.error);
    });
  } finally { db.close(); }
}

async function deleteDevicePrivateKey(deviceId) {
  const db = await openDeviceKeyStore();
  try {
    await new Promise((resolve, reject) => {
      const tx = db.transaction(DEVICE_KEY_STORE, 'readwrite');
      tx.objectStore(DEVICE_KEY_STORE).delete(deviceId);
      tx.oncomplete = resolve;
      tx.onerror = () => reject(tx.error);
    });
  } finally { db.close(); }
}

function toBase64Url(bytes) {
  let binary = '';
  for (const byte of new Uint8Array(bytes)) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

const api = {
  url: SUPABASE_URL,
  async getSession() {
    const result = await client.auth.getSession();
    return unwrap(result)?.session || null;
  },
  async getUser() {
    const result = await client.auth.getUser();
    return unwrap(result)?.user || null;
  },
  async signIn(email, password) {
    return unwrap(await client.auth.signInWithPassword({ email: String(email || '').trim(), password }));
  },
  async signUp(email, password, displayName) {
    return unwrap(await client.auth.signUp({
      email: String(email || '').trim(),
      password,
      options: { data: { display_name: String(displayName || '').trim() } }
    }));
  },
  async signOut() {
    return unwrap(await client.auth.signOut());
  },
  onAuthStateChange(callback) {
    return client.auth.onAuthStateChange((event, session) => {
      try { callback?.(event, session || null); } catch (error) { console.error('[Factoori cloud auth]', error); }
    }).data.subscription;
  },
  async listBusinesses(userId) {
    if (!userId) throw new Error('برای دریافت کسب‌وکارها ابتدا وارد حساب شوید.');
    const memberships = unwrap(await client.from('business_members')
      .select('business_id,role_code,status')
      .eq('user_id', userId)
      .eq('status', 'active')) || [];
    if (!memberships.length) return [];
    const ids = [...new Set(memberships.map(row => row.business_id).filter(Boolean))];
    const businesses = unwrap(await client.from('businesses')
      .select('id,name,status,owner_user_id')
      .in('id', ids)) || [];
    const roles = new Map(memberships.map(row => [row.business_id, row.role_code]));
    return businesses.map(row => ({ ...row, role_code: roles.get(row.id) || 'viewer' }));
  },
  async createBusiness(name) {
    const result = unwrap(await client.rpc('create_business', { p_name: String(name || '').trim() }));
    return typeof result === 'string' ? result : Array.isArray(result) ? result[0] : result;
  },
  async getEntitlements(businessId) {
    return unwrap(await client.rpc('get_business_entitlements', { p_business_id: businessId })) || [];
  },
  async createDocumentDraft(payload) {
    return unwrap(await client.rpc('create_document_draft', {
      p_business_id: payload.businessId,
      p_document_type: payload.documentType,
      p_contact_id: payload.contactId || null,
      p_warehouse_id: payload.warehouseId || null,
      p_fiscal_period_id: payload.fiscalPeriodId || null,
      p_document_date: payload.documentDate,
      p_due_date: payload.dueDate || null,
      p_notes: payload.notes || null,
      p_discount_amount: payload.discountAmount || 0,
      p_tax_rate: payload.taxRate ?? null,
      p_items: payload.items || [],
      p_idempotency_key: payload.idempotencyKey
    }));
  },
  async registerSyncDevice(payload) {
    if (!payload?.businessId) throw new Error('کسب‌وکار برای ثبت دستگاه مشخص نشده است.');
    if (!globalThis.crypto?.subtle || !globalThis.indexedDB) {
      throw new Error('این دستگاه از ذخیره‌سازی کلید و امضای رمزنگاری‌شده پشتیبانی نمی‌کند.');
    }
    const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const publicJwk = await crypto.subtle.exportKey('jwk', pair.publicKey);
    const privateJwk = await crypto.subtle.exportKey('jwk', pair.privateKey);
    const privateKey = await crypto.subtle.importKey('jwk', privateJwk,
      { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
    delete privateJwk.d;
    const deviceId = unwrap(await client.rpc('register_sync_device_secure', {
      p_business_id: payload.businessId,
      p_device_name: payload.deviceName || 'Factoori device',
      p_platform: payload.platform || 'android',
      p_device_public_key: { kty: publicJwk.kty, crv: publicJwk.crv, x: publicJwk.x, y: publicJwk.y }
    }));
    try {
      await saveDevicePrivateKey(deviceId, payload.businessId, privateKey);
      try { localStorage.setItem('factoori:sync-device:' + payload.businessId, deviceId); }
      catch (storageError) { await deleteDevicePrivateKey(deviceId); throw storageError; }
    } catch (error) {
      await client.rpc('revoke_sync_device', { p_business_id: payload.businessId, p_device_id: deviceId });
      throw error;
    }
    return { deviceId, businessId: payload.businessId, proofRequired: true };
  },
  async ensureSyncDevice(payload) {
    if (!payload?.businessId) throw new Error('کسب‌وکار برای تأیید دستگاه مشخص نشده است.');
    let deviceId = '';
    try { deviceId = localStorage.getItem('factoori:sync-device:' + payload.businessId) || ''; } catch {}
    if (deviceId && await getDevicePrivateKey(deviceId)) {
      return await api.proveSyncDevice({ businessId: payload.businessId, deviceId });
    }
    if (deviceId) {
      await this.revokeSyncDevice(payload.businessId, deviceId);
    }
    const registered = await this.registerSyncDevice(payload);
    return await api.proveSyncDevice({ businessId: payload.businessId, deviceId: registered.deviceId });
  },
  async proveSyncDevice(payload) {
    if (!payload?.businessId || !payload?.deviceId) throw new Error('دستگاه برای تأیید مشخص نشده است.');
    const privateKey = await getDevicePrivateKey(payload.deviceId);
    if (!privateKey) throw new Error('کلید خصوصی این دستگاه پیدا نشد؛ دستگاه را دوباره ثبت کنید.');
    const challenge = unwrap(await client.rpc('create_sync_device_challenge', {
      p_business_id: payload.businessId, p_device_id: payload.deviceId
    }));
    const signedMessage = [challenge.challenge_id, challenge.nonce, challenge.business_id,
      challenge.device_id, challenge.user_id].join('.');
    const signature = await crypto.subtle.sign(
      { name: 'ECDSA', hash: 'SHA-256' }, privateKey, new TextEncoder().encode(signedMessage)
    );
    const proof = unwrap(await client.functions.invoke('prove-sync-device', {
      body: { challenge_id: challenge.challenge_id, nonce: challenge.nonce, signature: toBase64Url(signature) }
    }));
    if (!proof?.verified) throw new Error('تأیید رمزنگاری‌شده دستگاه انجام نشد.');
    return proof;
  },
  getSyncDeviceId(businessId) {
    try { return localStorage.getItem('factoori:sync-device:' + businessId) || ''; } catch { return ''; }
  },
  async syncPush(payload) {
    if (!payload?.businessId || !payload?.deviceId || !Array.isArray(payload?.operations) || payload.operations.length > 100) {
      throw new Error('بسته همگام‌سازی معتبر نیست؛ حداکثر ۱۰۰ عملیات مجاز است.');
    }
    return unwrap(await client.rpc('sync_push', {
      p_business_id: payload.businessId,
      p_device_id: payload.deviceId,
      p_operations: payload.operations
    }));
  },
  async syncPull(payload) {
    if (!payload?.businessId || !payload?.deviceId) throw new Error('کسب‌وکار یا دستگاه همگام‌سازی مشخص نشده است.');
    return unwrap(await client.rpc('sync_pull', {
      p_business_id: payload.businessId,
      p_device_id: payload.deviceId,
      p_since_revision: Math.max(0, Number(payload.sinceRevision) || 0),
      p_limit: Math.min(500, Math.max(1, Number(payload.limit) || 200))
    }));
  },
  async revokeSyncDevice(businessId, deviceId) {
    const result = unwrap(await client.rpc('revoke_sync_device', {
      p_business_id: businessId, p_device_id: deviceId
    }));
    await deleteDevicePrivateKey(deviceId);
    try { if (localStorage.getItem('factoori:sync-device:' + businessId) === deviceId) localStorage.removeItem('factoori:sync-device:' + businessId); } catch {}
    return result;
  },
  async postJournalEntry(payload) {
    if (!payload?.businessId || !payload?.entryDate || !payload?.idempotencyKey || !Array.isArray(payload?.lines)) {
      throw new Error('اطلاعات سند حسابداری کامل نیست.');
    }
    return unwrap(await client.rpc('post_journal_entry', {
      p_business_id: payload.businessId,
      p_entry_date: payload.entryDate,
      p_description: payload.description || null,
      p_fiscal_period_id: payload.fiscalPeriodId || null,
      p_lines: payload.lines,
      p_idempotency_key: payload.idempotencyKey
    }));
  },
  async postStockTransfer(payload) {
    if (!payload?.businessId || !payload?.fromWarehouseId || !payload?.toWarehouseId
      || !payload?.transferDate || !payload?.idempotencyKey || !Array.isArray(payload?.items)) {
      throw new Error('اطلاعات انتقال انبار کامل نیست.');
    }
    return unwrap(await client.rpc('post_stock_transfer', {
      p_business_id: payload.businessId,
      p_from_warehouse_id: payload.fromWarehouseId,
      p_to_warehouse_id: payload.toWarehouseId,
      p_transfer_date: payload.transferDate,
      p_note: payload.note || null,
      p_items: payload.items,
      p_idempotency_key: payload.idempotencyKey
    }));
  },
  async getClientHealth() {
    // A successful Auth session alone does not mean the shared-account schema
    // has been deployed. Probe every relation required by the account UI and
    // verify that the entitlements RPC is present before enabling business actions.
    const relationChecks = await Promise.all([
      client.from('profiles').select('id').limit(0),
      client.from('businesses').select('id').limit(0),
      client.from('business_members').select('business_id').limit(0),
      client.from('permission_catalog').select('code').limit(0),
      client.from('documents').select('id').limit(0),
      client.from('business_settings').select('business_id').limit(0)
    ]);
    if (relationChecks.some(result => result.error)) return false;

    // Use a deliberately nonexistent business only to probe the RPC endpoint.
    // A business-not-found / authorization error proves the function exists;
    // PostgREST's PGRST202 means the function itself is not exposed/found.
    const probeBusinessId = '00000000-0000-0000-0000-000000000000';
    const [entitlementProbe, createBusinessProbe, draftProbe] = await Promise.all([
      client.rpc('get_business_entitlements', { p_business_id: probeBusinessId }),
      // Empty name is intentionally invalid; the function must reject it without creating a row.
      client.rpc('create_business', { p_name: '' }),
      // Unknown business is intentionally unauthorized; this only verifies the RPC is deployed.
      client.rpc('create_document_draft', {
        p_business_id: probeBusinessId,
        p_document_type: 'goods_sale',
        p_items: []
      })
    ]);
    return [entitlementProbe, createBusinessProbe, draftProbe]
      .every(result => result.error?.code !== 'PGRST202');
  }
};

window.FactooriCloud = Object.freeze(api);
