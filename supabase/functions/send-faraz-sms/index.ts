import { importJWK, jwtVerify } from "https://esm.sh/jose@5";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};
const reply = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: cors });
const PUBLIC_JWK = {
  kty: "EC", crv: "P-256",
  x: "_r1Nk5fzHPiAWAIVp5U9i9eg-3NY0WetWIctLudfAfw",
  y: "3PV_mnmE9xxwwB44ooFJxteuEmfE2POLhwiBQQah8uQ", ext: true
};

function toIranE164(value: string): string {
  const raw = String(value || '').trim().replace(/[\s()-]/g, '');
  if (raw.startsWith('+')) return raw;
  if (raw.startsWith('0098')) return '+' + raw.slice(2);
  if (raw.startsWith('98')) return '+' + raw;
  if (raw.startsWith('0')) return '+98' + raw.slice(1);
  return '+98' + raw;
}

Deno.serve(async req => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ ok: false, error: "method_not_allowed" }, 405);
  try {
    const auth = req.headers.get("Authorization") || "";
    const token = auth.replace(/^Bearer\s+/i, "").trim();
    if (!token) return reply({ ok: false, error: "license_required" }, 401);
    const publicKey = await importJWK(PUBLIC_JWK, "ES256");
    const verified = await jwtVerify(token, publicKey, {
      issuer: "factori-license", audience: "com.factori.app"
    });
    if (verified.payload.permanent !== true || typeof verified.payload.device !== "string" || !verified.payload.sub)
      return reply({ ok: false, error: "invalid_license" }, 401);

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceKey) throw new Error("Supabase configuration missing");
    const admin = createClient(supabaseUrl, serviceKey);
    const activationId = String(verified.payload.sub);
    const { data: activation, error: activationError } = await admin
      .from("factori_license_activations")
      .select("id, license_id, device_thumbprint")
      .eq("id", activationId).maybeSingle();
    if (activationError || !activation || activation.device_thumbprint !== verified.payload.device)
      return reply({ ok: false, error: "license_not_active" }, 401);
    const { data: license, error: licenseError } = await admin
      .from("factori_license_keys").select("status").eq("id", activation.license_id).maybeSingle();
    if (licenseError || license?.status !== "active")
      return reply({ ok: false, error: "license_not_active" }, 401);
    const body = await req.json();
    const apiKey = String(body.apiKey || "").trim();
    const fromNumber = toIranE164(body.fromNumber);
    const patternCode = String(body.patternCode || '').trim();
    const recipient = toIranE164(body.recipient);
    const params = body.params;
    if (!apiKey || !/^\+[1-9]\d{7,14}$/.test(fromNumber) || !patternCode ||
        !/^\+989\d{9}$/.test(recipient) ||
        !params || typeof params !== 'object' || Array.isArray(params))
      return reply({ ok: false, error: 'invalid_sms_request' }, 400);
    if (apiKey.length > 512 || fromNumber.length > 40 || patternCode.length > 120)
      return reply({ ok: false, error: "invalid_sms_config" }, 400);

    const upstream = await fetch("https://edge.ippanel.com/v1/api/send", {
      method: "POST",
      headers: { "Authorization": apiKey, "Content-Type": "application/json" },
      body: JSON.stringify({
        sending_type: "pattern", from_number: fromNumber,
        code: patternCode, recipients: [recipient], params
      })
    });
    const raw = await upstream.text();
    let result: unknown = raw;
    try { result = raw ? JSON.parse(raw) : {}; } catch { /* retain provider text */ }
    if (!upstream.ok || (result && typeof result === "object" && (result as any).meta?.status === false)) return reply({ ok: false, error: "provider_error", status: upstream.status, detail: result }, 502);
    return reply({ ok: true, provider: result });
  } catch (error) {
    const message = String((error as Error)?.message || error);
    const authFailure = /JWT|signature|issuer|audience|claim/i.test(message);
    return reply({ ok: false, error: authFailure ? "invalid_license" : "sms_gateway_error", detail: authFailure ? "اعتبارسنجی لایسنس ناموفق بود" : message.slice(0, 300) }, authFailure ? 401 : 500);
  }
});
