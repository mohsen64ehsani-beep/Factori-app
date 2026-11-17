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
  async getClientHealth() {
    // A successful Auth session alone does not mean the shared-account schema
    // has been deployed. Probe every relation required by the account UI and
    // verify that the entitlements RPC is present before enabling business actions.
    const checks = await Promise.all([
      client.from('profiles').select('id').limit(0),
      client.from('businesses').select('id').limit(0),
      client.from('business_members').select('business_id').limit(0),
      client.from('permission_catalog').select('code').limit(0),
      client.from('documents').select('id').limit(0),
      client.from('business_settings').select('business_id').limit(0),
      client.rpc('get_business_entitlements', { p_business_id: '00000000-0000-0000-0000-000000000000' })
    ]);
    return checks.every(result => !result.error);
  }
};

window.FactooriCloud = Object.freeze(api);
