import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json"
};

const response = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: cors });

async function sha256(value: string) {
  const bytes = new Uint8Array(
    await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(value)
    )
  );

  return Array.from(bytes)
    .map(x => x.toString(16).padStart(2, "0"))
    .join("");
}

function generateCode() {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(20));

  const chars = Array.from(bytes, x =>
    alphabet[x % alphabet.length]
  ).join("");

  return "FACT-" + (chars.match(/.{1,5}/g) ?? []).join("-");
}

Deno.serve(async req => {

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: cors });
  }

  try {

    const adminPassword =
      Deno.env.get("FACTORY_LICENSE_ADMIN_PASSWORD");

    const supabaseUrl =
      Deno.env.get("SUPABASE_URL");

    const serviceKey =
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

    if (!adminPassword || !supabaseUrl || !serviceKey) {
      throw new Error("Server configuration missing");
    }

    const body = await req.json();

    if (String(body.password ?? "") !== adminPassword) {
      return response({
        ok: false,
        error: "رمز مدیر اشتباه است"
      }, 401);
    }

    const db = createClient(
      supabaseUrl,
      serviceKey,
      { auth: { persistSession: false } }
    );

    // ایجاد لایسنس
    if (body.action === "create") {

      const code = generateCode();

      const { data, error } = await db
        .from("factori_license_keys")
        .insert({
          key_hash: await sha256(code),
          status: "unused"
        })
        .select("id,status,created_at")
        .single();

      if (error) throw error;

      return response({
        ok: true,
        code,
        license: data
      });
    }

    // نمایش فهرست
    if (body.action === "list") {

      const { data, error } = await db
        .from("factori_license_keys")
        .select("id,status,created_at,activated_at,revoked_at")
        .order("created_at", { ascending: false })
        .limit(200);

      if (error) throw error;

      return response({
        ok: true,
        licenses: data ?? []
      });
    }

    // لغو لایسنس استفاده‌نشده
    if (body.action === "revoke") {

      const { data, error } = await db
        .from("factori_license_keys")
        .update({
          status: "revoked",
          revoked_at: new Date().toISOString()
        })
        .eq("id", String(body.id ?? ""))
        .eq("status", "unused")
        .select("id,status")
        .maybeSingle();

      if (error) throw error;

      if (!data) {
        return response({
          ok: false,
          error: "فقط کد استفاده‌نشده قابل لغو است"
        }, 409);
      }

      return response({
        ok: true,
        license: data
      });
    }

    return response({
      ok: false,
      error: "عملیات نامعتبر است"
    }, 400);

  } catch (error) {

    return response({
      ok: false,
      error: String((error as Error).message ?? error)
    }, 500);

  }

});
