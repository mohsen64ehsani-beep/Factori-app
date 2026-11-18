// Classify Supabase health-probe errors without mistaking network failures
// for proof that the remote database schema is available.
export function isSchemaProbeErrorReady(error) {
  if (!error) return true;
  const code = String(error.code || '');
  if (/^[0-9A-Z]{5}$/.test(code)) return true; // PostgreSQL SQLSTATE
  if (/^PGRST[0-9]{3}$/.test(code)) return code !== 'PGRST202';
  return false;
}
