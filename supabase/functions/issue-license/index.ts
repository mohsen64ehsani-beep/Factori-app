import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "https://factoori.ir",
  "Access-Control-Allow-Headers": "content-type, x-factoori-issue-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};

const reply = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: corsHeaders });

const encoder = new TextEncoder();

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("");
}

function toBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function fromBase64Url(value: string): Uint8Array {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(normalized + "=".repeat((4 - normalized.length % 4) % 4));
  return Uint8Array.from(binary, c => c.charCodeAt(0));
}

async function sha256(value: string): Promise<string> {
  return bytesToHex(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value))));
}

function constantTimeEqual(a: string, b: string): boolean {
  const aa = encoder.encode(a);
  const bb = encoder.encode(b);
  if (aa.length !== bb.length) return false;
  let diff = 0;
  for (let i = 0; i < aa.length; i++) diff |= aa[i] ^ bb[i];
  return diff === 0;
}

async function encryptionKey() {
  const raw = Deno.env.get("FACTOORI_LICENSE_ENCRYPTION_KEY") ?? "";
  let bytes: Uint8Array;
  try {
    bytes = fromBase64Url(raw);
  } catch {
    throw new Error("FACTOORI_LICENSE_ENCRYPTION_KEY must be base64url-encoded 32 bytes");
  }
  if (bytes.length !== 32) throw new Error("FACTOORI_LICENSE_ENCRYPTION_KEY must decode to exactly 32 bytes");
  return crypto.subtle.importKey("raw", bytes, "AES-GCM", false, ["encrypt", "decrypt"]);
}

async function encryptKey(plain: string, key: CryptoKey): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = new Uint8Array(await crypto.subtle.encrypt(
    { name: "AES-GCM", iv }, key, encoder.encode(plain)
  ));
  return `v1.${toBase64Url(iv)}.${toBase64Url(encrypted)}`;
}

async function decryptKey(value: string, key: CryptoKey): Promise<string> {
  const parts = value.split(".");
  if (parts.length !== 3 || parts[0] !== "v1") throw new Error("Unsupported encrypted license format");
  const plain = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: fromBase64Url(parts[1]) },
    key,
    fromBase64Url(parts[2])
  );
  return new TextDecoder().decode(plain);
}

function generateLicenseKey(): string {
  const raw = crypto.getRandomValues(new Uint8Array(20));
  const hex = bytesToHex(raw).toUpperCase();
  const groups = hex.match(/.{1,5}/g) ?? [];
  return "FCT-" + groups.join("-");
}

type ExistingLicense = {
  id: string;
  order_id: string | null;
  encrypted_key: string | null;
  payment_reference: string | null;
  amount_paid_toman: number | null;
  status: string;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply({ ok: false, error: "method_not_allowed" }, 405);

  try {
    const expectedSecret = Deno.env.get("FACTOORI_ISSUE_SECRET") ?? "";
    const suppliedSecret = req.headers.get("x-factoori-issue-secret") ?? "";
    if (!expectedSecret || !suppliedSecret || !constantTimeEqual(expectedSecret, suppliedSecret)) {
      return reply({ ok: false, error: "unauthorized" }, 401);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) throw new Error("Supabase server configuration is missing");

    const body = await req.json();
    const orderId = String(body.order_id ?? "").trim();
    const paymentReference = String(body.payment_reference ?? "").trim();
    const amountToman = Number(body.amount_toman);
    const expectedAmount = Number(Deno.env.get("FACTOORI_PRODUCT_PRICE_TOMAN") ?? "1500000");

    if (!/^[A-Za-z0-9:_-]{4,100}$/.test(orderId) ||
        !/^[A-Za-z0-9._:-]{3,160}$/.test(paymentReference) ||
        !Number.isSafeInteger(amountToman) ||
        amountToman !== expectedAmount) {
      return reply({ ok: false, error: "invalid_verified_payment_payload" }, 400);
    }

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const cryptoKey = await encryptionKey();

    const loadExisting = async (): Promise<ExistingLicense | null> => {
      const { data, error } = await admin
        .from("factori_license_keys")
        .select("id,order_id,encrypted_key,payment_reference,amount_paid_toman,status")
        .eq("order_id", orderId)
        .maybeSingle();
      if (error) throw error;
      return data as ExistingLicense | null;
    };

    const returnExisting = async (row: ExistingLicense) => {
      if (row.payment_reference !== paymentReference ||
          Number(row.amount_paid_toman) !== amountToman ||
          !row.encrypted_key) {
        return reply({ ok: false, error: "order_already_issued_or_payment_mismatch" }, 409);
      }
      const licenseKey = await decryptKey(row.encrypted_key, cryptoKey);
      return reply({
        ok: true,
        order_id: orderId,
        license_key: licenseKey,
        status: row.status,
        permanent: true,
        reused: true,
      });
    };

    const existing = await loadExisting();
    if (existing) return await returnExisting(existing);

    for (let attempt = 0; attempt < 5; attempt++) {
      const licenseKey = generateLicenseKey();
      const keyHash = await sha256(licenseKey);
      const encrypted = await encryptKey(licenseKey, cryptoKey);

      const { error } = await admin.from("factori_license_keys").insert({
        key_hash: keyHash,
        status: "unused",
        order_id: orderId,
        encrypted_key: encrypted,
        payment_reference: paymentReference,
        payment_gateway: String(body.payment_gateway ?? "verified_gateway").slice(0, 40),
        amount_paid_toman: amountToman,
        payment_verified_at: new Date().toISOString(),
      });

      if (!error) {
        return reply({
          ok: true,
          order_id: orderId,
          license_key: licenseKey,
          status: "unused",
          permanent: true,
          reused: false,
        }, 201);
      }

      if (error.code === "23505") {
        const concurrent = await loadExisting();
        if (concurrent) return await returnExisting(concurrent);
        // A key_hash collision is extraordinarily unlikely; generate another key.
        continue;
      }
      throw error;
    }

    return reply({ ok: false, error: "could_not_allocate_unique_license" }, 500);
  } catch (error) {
    console.error("[issue-license]", error);
    return reply({ ok: false, error: "server_error" }, 500);
  }
});
