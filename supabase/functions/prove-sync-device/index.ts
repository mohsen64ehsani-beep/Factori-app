import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function fromBase64Url(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

function toHex(bytes: ArrayBuffer): string {
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  const authorization = req.headers.get("Authorization") || "";
  const token = authorization.replace(/^Bearer\s+/i, "");
  if (!token) return json(401, { error: "authentication_required" });

  const url = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const userClient = createClient(url, anonKey, { global: { headers: { Authorization: `Bearer ${token}` } }, auth: { persistSession: false } });
  const { data: userData, error: userError } = await userClient.auth.getUser(token);
  if (userError || !userData.user) return json(401, { error: "invalid_session" });

  let body: { challenge_id?: string; nonce?: string; signature?: string };
  try { body = await req.json(); } catch { return json(400, { error: "invalid_json" }); }
  if (!body.challenge_id || !body.nonce || !body.signature) return json(400, { error: "missing_proof_fields" });
  if (!/^[A-Za-z0-9_-]{86}$/.test(body.signature)) return json(400, { error: "invalid_signature_format" });
  if (!/^[0-9a-f-]{36}$/i.test(body.challenge_id) || !/^[0-9a-f]{64}$/i.test(body.nonce)) {
    return json(400, { error: "invalid_challenge_format" });
  }

  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: challenge, error: challengeError } = await admin
    .from("sync_device_challenges")
    .select("id,business_id,device_id,user_id,challenge_hash,expires_at,consumed_at,sync_devices!inner(device_public_key,device_key_thumbprint,status,proof_version)")
    .eq("id", body.challenge_id)
    .maybeSingle();
  if (challengeError || !challenge) return json(403, { error: "challenge_not_found" });
  if (challenge.user_id !== userData.user.id || challenge.consumed_at || Date.parse(challenge.expires_at) <= Date.now()) {
    return json(403, { error: "challenge_expired_or_consumed" });
  }

  const nonceHash = toHex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body.nonce)));
  if (nonceHash !== challenge.challenge_hash) return json(403, { error: "challenge_mismatch" });

  const device = Array.isArray(challenge.sync_devices) ? challenge.sync_devices[0] : challenge.sync_devices;
  if (!device || device.status !== "active" || device.proof_version !== 1) return json(403, { error: "device_inactive" });
  const jwk = device.device_public_key;
  if (!jwk || jwk.kty !== "EC" || jwk.crv !== "P-256" || jwk.d || !jwk.x || !jwk.y) {
    return json(403, { error: "invalid_registered_public_key" });
  }

  const canonical = JSON.stringify({ crv: "P-256", kty: "EC", x: jwk.x, y: jwk.y });
  const thumbprint = toHex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(canonical)));
  if (thumbprint !== device.device_key_thumbprint) return json(403, { error: "key_thumbprint_mismatch" });

  const signedMessage = [challenge.id, body.nonce, challenge.business_id, challenge.device_id, challenge.user_id].join(".");
  let valid = false;
  try {
    const publicKey = await crypto.subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      publicKey,
      fromBase64Url(body.signature),
      new TextEncoder().encode(signedMessage),
    );
  } catch { valid = false; }
  if (!valid) return json(403, { error: "invalid_device_signature" });

  const { data: finalized, error: finalizeError } = await admin.rpc("finalize_sync_device_proof", {
    p_challenge_id: challenge.id,
    p_business_id: challenge.business_id,
    p_device_id: challenge.device_id,
    p_user_id: challenge.user_id,
    p_key_thumbprint: thumbprint,
  });
  if (finalizeError || finalized !== true) return json(409, { error: "proof_finalize_failed" });
  return json(200, { verified: true, device_id: challenge.device_id });
});
