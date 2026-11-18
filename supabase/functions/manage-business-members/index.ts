import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: cors });

const allowedRoles = new Set(["admin", "accountant", "sales", "viewer", "warehouse"]);
const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply(405, { error: "method_not_allowed" });

  try {
    const authorization = req.headers.get("Authorization") || "";
    const token = authorization.replace(/^Bearer\s+/i, "");
    if (!token) return reply(401, { error: "authentication_required" });

    const url = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !anonKey || !serviceKey) throw new Error("Supabase configuration is missing");

    const userClient = createClient(url, anonKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: authData, error: authError } = await userClient.auth.getUser(token);
    if (authError || !authData.user) return reply(401, { error: "invalid_session" });
    const actorId = authData.user.id;

    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const body = await req.json();
    const businessId = String(body?.businessId || "");
    if (!/^[0-9a-f-]{36}$/i.test(businessId)) return reply(400, { error: "invalid_business_id" });

    const { data: actor, error: actorError } = await admin.from("business_members")
      .select("role_code,status").eq("business_id", businessId).eq("user_id", actorId).maybeSingle();
    if (actorError || !actor || actor.status !== "active") return reply(403, { error: "business_access_denied" });

    const owner = actor.role_code === "owner";
    const { data: rolePermission, error: rolePermissionError } = await admin
      .from("business_role_permissions").select("allowed")
      .eq("role_code", actor.role_code).eq("permission_code", "members.manage").maybeSingle();
    if (rolePermissionError) throw rolePermissionError;
    const { data: override, error: overrideError } = await admin
      .from("business_member_permission_overrides").select("allowed")
      .eq("business_id", businessId).eq("user_id", actorId)
      .eq("permission_code", "members.manage").maybeSingle();
    if (overrideError) throw overrideError;
    const canManage = owner || (override ? override.allowed : !!rolePermission?.allowed);
    if (!canManage) return reply(403, { error: "member_management_not_permitted" });

    if (body.action === "list") {
      const { data: members, error: membersError } = await admin.from("business_members")
        .select("user_id,role_code,status,joined_at,created_at")
        .eq("business_id", businessId).order("created_at", { ascending: true });
      if (membersError) throw membersError;
      const result = await Promise.all((members || []).map(async (member) => {
        const [{ data: profile, error: profileError }, { data: userResult, error: userError },
          { data: overrides, error: permissionsError }] = await Promise.all([
          admin.from("profiles").select("display_name").eq("id", member.user_id).maybeSingle(),
          admin.auth.admin.getUserById(member.user_id),
          admin.from("business_member_permission_overrides")
            .select("permission_code,allowed").eq("business_id", businessId).eq("user_id", member.user_id),
        ]);
        if (profileError) throw profileError;
        if (userError) throw userError;
        if (permissionsError) throw permissionsError;
        return {
          user_id: member.user_id,
          email: userResult.user?.email || "",
          display_name: profile?.display_name || userResult.user?.user_metadata?.display_name || "",
          role_code: member.role_code,
          status: member.status,
          joined_at: member.joined_at,
          permission_overrides: overrides || [],
        };
      }));
      return reply(200, { members: result });
    }

    if (body.action !== "create") return reply(400, { error: "invalid_action" });

    const email = String(body.email || "").trim().toLowerCase();
    const password = String(body.password || "");
    const displayName = String(body.displayName || "").trim().slice(0, 120);
    const roleCode = String(body.roleCode || "viewer");
    const requested = Array.isArray(body.permissionOverrides) ? body.permissionOverrides : [];
    if (!emailPattern.test(email) || email.length > 254) return reply(400, { error: "invalid_email" });
    if (password.length < 8 || password.length > 128) return reply(400, { error: "password_must_be_8_to_128_chars" });
    if (!displayName) return reply(400, { error: "display_name_required" });
    if (!allowedRoles.has(roleCode)) return reply(400, { error: "invalid_role" });
    if (roleCode === "admin" && !owner) return reply(403, { error: "only_owner_can_assign_admin" });
    if (requested.length > 60) return reply(400, { error: "too_many_permission_overrides" });

    const { data: catalog, error: catalogError } = await admin.from("permission_catalog")
      .select("code,is_sensitive");
    if (catalogError) throw catalogError;
    const permissionMap = new Map((catalog || []).map((item) => [item.code, item]));
    const seen = new Set<string>();
    const cleanOverrides: { code: string; allowed: boolean }[] = [];
    for (const item of requested) {
      const code = String(item?.code || "");
      const allowed = item?.allowed;
      const permission = permissionMap.get(code);
      if (!permission || typeof allowed !== "boolean" || seen.has(code)) {
        return reply(400, { error: "invalid_permission_override" });
      }
      if (allowed && permission.is_sensitive && !owner) {
        return reply(403, { error: "only_owner_can_grant_sensitive_permission", permission: code });
      }
      seen.add(code);
      cleanOverrides.push({ code, allowed });
    }

    const { data: created, error: createError } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { display_name: displayName },
    });
    if (createError || !created.user) {
      return reply(400, { error: createError?.message || "user_creation_failed" });
    }

    const { data: provisioned, error: provisionError } = await admin.rpc("provision_business_member", {
      p_business_id: businessId,
      p_user_id: created.user.id,
      p_role_code: roleCode,
      p_invited_by: actorId,
      p_permission_overrides: cleanOverrides,
    });
    if (provisionError || provisioned !== true) {
      await admin.auth.admin.deleteUser(created.user.id);
      throw provisionError || new Error("Member provisioning did not complete");
    }

    return reply(200, {
      ok: true,
      member: { user_id: created.user.id, email, display_name: displayName, role_code: roleCode, status: "active" },
    });
  } catch (error) {
    return reply(500, { error: "server_error", detail: String(error?.message || error) });
  }
});
