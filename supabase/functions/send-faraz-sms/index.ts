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

function normalizeIranMobile(value: string): string {
  let raw = String(value || "").trim().replace(/[\s()-]/g, "");
  if (raw.startsWith("+98")) raw = "0" + raw.slice(3);
  else if (raw.startsWith("0098")) raw = "0" + raw.slice(4);
  else if (raw.startsWith("98")) raw = "0" + raw.slice(2);
  if (!/^09\d{9}$/.test(raw)) throw new Error("invalid_recipient");
  return raw;
}

function normalizeLineNumber(value: string): string {
  const raw = String(value || "").trim().replace(/[\s()-]/g, "");
  if (!/^\d{5,20}$/.test(raw)) throw new Error("invalid_line_number");
  return raw;
}

async function farazRequest(url: string, apiKey: string, init: RequestInit): Promise<{ response: Response; data: any }> {
  const response = await fetch(url, {
    ...init,
    headers: { "Accept": "application/json", "Api-Key": apiKey, ...(init.headers || {}) },
    signal: AbortSignal.timeout(20000),
  });
  const raw = await response.text();
  let data: any = null;
  try { data = raw ? JSON.parse(raw) : {}; } catch { data = null; }
  return { response, data };
}
Deno.serve(async req => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ ok: false, error: "method_not_allowed" }, 405);
  try {
    const auth = req.headers.get("Authorization") || "";
    const token = auth.replace(/^Bearer\s+/i, "").trim();
    if (!token) return reply({ ok: false, error: "license_required" }, 401);
    const publicKey = await importJWK(PUBLIC_JWK, "ES256");
    const verified = await jwtVerify(token, publicKey, { issuer: "factori-license", audience: "com.factori.app" });
    if (verified.payload.permanent !== true || typeof verified.payload.device !== "string" || !verified.payload.sub)
      return reply({ ok: false, error: "invalid_license" }, 401);

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceKey) throw new Error("Supabase configuration missing");
    const admin = createClient(supabaseUrl, serviceKey);
    const activationId = String(verified.payload.sub);
    const { data: activation, error: activationError } = await admin
      .from("factori_license_activations").select("id, license_id, device_thumbprint")
      .eq("id", activationId).maybeSingle();
    if (activationError || !activation || activation.device_thumbprint !== verified.payload.device)
      return reply({ ok: false, error: "license_not_active" }, 401);
    const { data: license, error: licenseError } = await admin
      .from("factori_license_keys").select("status").eq("id", activation.license_id).maybeSingle();
    if (licenseError || license?.status !== "active")
      return reply({ ok: false, error: "license_not_active" }, 401);

    const body = await req.json();
    const apiKey = String(body.apiKey || "").trim();
    const patternCode = String(body.patternCode || "").trim();
    if (!apiKey || apiKey.length > 512 || !patternCode || patternCode.length > 120)
      return reply({ ok: false, error: "invalid_sms_config" }, 400);

    if (body.action === "pattern_details") {
      const { response, data } = await farazRequest(
        "https://api.iranpayamak.com/ws/v1/patterns/" + encodeURIComponent(patternCode), apiKey, { method: "GET" }
      );
      if (!response.ok || !data || (data.status && data.status !== "success"))
        return reply({ ok: false, error: "pattern_lookup_failed", status: response.status }, 502);
      const pattern = data.data ?? data;
      const attributes = Array.isArray(pattern.attributes) ? pattern.attributes.map((a: any) => ({
        name: String(a.name || ""), type: String(a.type || ""), length: Number(a.length || 0),
      })).filter((a: any) => a.name) : [];
      return reply({ ok: true, pattern: { code: patternCode, text: String(pattern.text || ""), description: String(pattern.description || ""), attributes } });
    }

    const lineNumber = normalizeLineNumber(body.fromNumber);
    const recipient = normalizeIranMobile(body.recipient);
    const attributes = body.params;
    if (!attributes || typeof attributes !== "object" || Array.isArray(attributes))
      return reply({ ok: false, error: "invalid_sms_request" }, 400);

    const { response, data } = await farazRequest("https://api.iranpayamak.com/ws/v1/sms/pattern", apiKey, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code: patternCode, attributes, recipient, line_number: lineNumber, number_format: "english" }),
    });
    if (!response.ok || !data || (data.status && data.status !== "success")) {
      console.error("FarazSMS pattern send failed", { status: response.status });
      return reply({ ok: false, error: "provider_error", status: response.status }, 502);
    }
    return reply({ ok: true, provider: { status: data.status || "success", messages: data.messages || "", data: data.data ?? null } });
  } catch (error) {
    const message = String((error as Error)?.message || error);
    if (message === "invalid_recipient") return reply({ ok: false, error: "invalid_recipient" }, 400);
    if (message === "invalid_line_number") return reply({ ok: false, error: "invalid_line_number" }, 400);
    const authFailure = /JWT|signature|issuer|audience|claim/i.test(message);
    const timeout = /timed out|timeout/i.test(message);
    return reply({ ok: false, error: authFailure ? "invalid_license" : timeout ? "provider_timeout" : "sms_gateway_error",
      detail: authFailure ? "اعتبارسنجی لایسنس ناموفق بود" : timeout ? "پاسخ فراز در زمان مقرر دریافت نشد." : "ارتباط با سرویس پیامک ناموفق بود." },
      authFailure ? 401 : timeout ? 504 : 500);
  }
});
