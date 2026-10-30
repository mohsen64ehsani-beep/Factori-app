import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { importJWK, SignJWT } from "https://esm.sh/jose@5";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

const reply = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: cors });

const hex = (b: Uint8Array) =>
  Array.from(b, x => x.toString(16).padStart(2, "0")).join("");

const hash = async (s: string) =>
  hex(new Uint8Array(await crypto.subtle.digest(
    "SHA-256", new TextEncoder().encode(s)
  )));

const decode = (s: string) => {
  const v = s.replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(v + "=".repeat((4 - v.length % 4) % 4));
  return Uint8Array.from(raw, c => c.charCodeAt(0));
};

Deno.serve(async req => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ ok: false }, 405);

  try {
    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !serviceKey) throw new Error("Supabase config missing");

    const admin = createClient(url, serviceKey);
    const body = await req.json();

    if (body.action === "issue_nonce") {
      const { data, error } = await admin.rpc("factori_issue_nonce");
      if (error) throw error;
      return reply({ ok: true, nonce: data });
    }

    if (body.action !== "activate")
      return reply({ ok: false, error: "invalid_action" }, 400);

    const licenseKey = String(body.licenseKey ?? "").trim();
    const nonce = String(body.nonce ?? "");
    const signature = String(body.signature ?? "");
    const jwk = body.deviceJwk;

    if (!licenseKey || !nonce || !signature ||
        jwk?.kty !== "EC" || jwk?.crv !== "P-256" ||
        typeof jwk.x !== "string" || typeof jwk.y !== "string" ||
        "d" in jwk) {
      return reply({ ok: false, error: "invalid_request" }, 400);
    }

    const privateText = Deno.env.get("FACTORY_LICENSE_SIGNING_PRIVATE_JWK");
    if (!privateText) throw new Error("Signing key missing");

    const signingKey = await importJWK(JSON.parse(privateText), "ES256");

    const publicKey = await crypto.subtle.importKey(
      "jwk",
      { kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y, ext: true },
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"]
    );

    const valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      publicKey,
      decode(signature),
      new TextEncoder().encode(nonce)
    );

    if (!valid)
      return reply({ ok: false, error: "invalid_device_signature" }, 401);

    const canonical = JSON.stringify({
      crv: "P-256", kty: "EC", x: jwk.x, y: jwk.y
    });

    const thumbprint = await hash(canonical);

    const { data, error } = await admin.rpc("factori_consume_license", {
      p_key_hash: await hash(licenseKey),
      p_device_jwk: {
        kty: "EC", crv: "P-256", x: jwk.x, y: jwk.y
      },
      p_device_thumbprint: thumbprint,
      p_nonce_hash: await hash(nonce)
    });

    if (error) throw error;
    if (!data?.ok)
      return reply({ ok: false, reason: data?.reason ?? "activation_failed" }, 403);

    const now = Math.floor(Date.now() / 1000);

    const token = await new SignJWT({
      device: thumbprint,
      permanent: true
    })
      .setProtectedHeader({ alg: "ES256", typ: "JWT" })
      .setIssuer("factori-license")
      .setAudience("com.factori.app")
      .setSubject(data.activation_id)
      .setIssuedAt(now)
      .sign(signingKey);

    return reply({
      ok: true,
      token,
      activation_id: data.activation_id
    });

  } catch (e) {
    return reply({
      ok: false,
      error: "server_error",
      detail: String(e?.message ?? e)
    }, 500);
  }
});
      
