import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const allowedOrigins = new Set(["https://mohsen64ehsani-beep.github.io","https://factoori.ir","https://www.factoori.ir"]);
const cors = (req:Request) => { const origin=req.headers.get("origin")||""; return {"Access-Control-Allow-Origin":allowedOrigins.has(origin)?origin:"https://mohsen64ehsani-beep.github.io","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Vary":"Origin","Content-Type":"application/json","Cache-Control":"no-store"}; };
const reply=(req:Request,data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:cors(req)});
async function hash(s:string){const b=new Uint8Array(await crypto.subtle.digest("SHA-256",new TextEncoder().encode(s)));return Array.from(b).map(x=>x.toString(16).padStart(2,"0")).join("")}
function makeCode(){const a="ABCDEFGHJKLMNPQRSTUVWXYZ23456789";const b=crypto.getRandomValues(new Uint8Array(20));const s=Array.from(b,x=>a[x%a.length]).join("");return "FACT-"+(s.match(/.{1,5}/g)||[]).join("-")}
async function log(db:any,action:string,id:string|null,oldStatus:string|null,newStatus:string|null){const {error}=await db.from("factori_license_admin_events").insert({action,license_id:id,previous_status:oldStatus,new_status:newStatus});if(error)console.error(error.message)}
async function count(db:any,status?:string){let q=db.from("factori_license_keys").select("id",{count:"exact",head:true});if(status)q=q.eq("status",status);const {count,error}=await q;if(error)throw error;return count||0}
const validEmail=(s:string)=>s.length<=254&&/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s);
Deno.serve(async req=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors(req)});
 if(req.method!=="POST")return reply(req,{ok:false,error:"method_not_allowed"},405);
 try{
  const password=Deno.env.get("FACTORY_LICENSE_ADMIN_PASSWORD"),url=Deno.env.get("SUPABASE_URL"),key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if(!password||!url||!key)throw new Error("Server configuration missing");
  const body=await req.json();if(String(body.password??"")!==password)return reply(req,{ok:false,error:"رمز مدیر اشتباه است"},401);
  const db=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
  if(body.action==="create"){
   const email=String(body.owner_email??"").trim().toLowerCase(),licenseType=String(body.license_type??"permanent");
   if(!validEmail(email))return reply(req,{ok:false,error:"ایمیل معتبر وارد کنید"},400);
   if(!["permanent","trial_24h"].includes(licenseType))return reply(req,{ok:false,error:"نوع لایسنس نامعتبر است"},400);
   const code=makeCode(),expiresAt=licenseType==="trial_24h"?new Date(Date.now()+86400000).toISOString():null;
   const {data,error}=await db.from("factori_license_keys").insert({key_hash:await hash(code),status:"unused",owner_email:email,license_type:licenseType,expires_at:expiresAt})
    .select("id,status,created_at,owner_email,license_type,expires_at").single();
   if(error)throw error;
   await log(db,licenseType==="trial_24h"?"create_trial":"create",data.id,null,"unused");
   return reply(req,{ok:true,code,license:data});
  }
  if(body.action==="set_email"){
   const id=String(body.id??""),email=String(body.owner_email??"").trim().toLowerCase();
   if(!id||!validEmail(email))return reply(req,{ok:false,error:"شناسه و ایمیل معتبر لازم است"},400);
   const {data:before,error:readError}=await db.from("factori_license_keys").select("id,status,owner_email").eq("id",id).maybeSingle();
   if(readError)throw readError;if(!before||before.status!=="unused")return reply(req,{ok:false,error:"اتصال یا تغییر ایمیل فقط برای لایسنس استفاده‌نشده مجاز است"},409);
   const {data,error}=await db.from("factori_license_keys").update({owner_email:email}).eq("id",id).eq("status","unused")
    .select("id,status,owner_email,license_type,expires_at").maybeSingle();
   if(error)throw error;if(!data)return reply(req,{ok:false,error:"وضعیت لایسنس تغییر کرده است؛ بروزرسانی کنید"},409);
   await log(db,"assign_email",id,before.status,data.status);return reply(req,{ok:true,license:data});
  }
  if(body.action==="upgrade_to_permanent"){
   const id=String(body.id??"");
   if(!id)return reply(req,{ok:false,error:"شناسه لایسنس الزامی است"},400);
   const {data:before,error:readError}=await db.from("factori_license_keys").select("id,status,license_type,expires_at,owner_email").eq("id",id).maybeSingle();
   if(readError)throw readError;
   if(!before||before.status!=="active"||before.license_type!=="trial_24h"||!before.expires_at||Date.parse(before.expires_at)<=Date.now())
    return reply(req,{ok:false,error:"فقط لایسنس آزمایشی فعال و منقضی‌نشده قابل ارتقا است"},409);
   const {data,error}=await db.from("factori_license_keys").update({license_type:"permanent",expires_at:null})
    .eq("id",id).eq("status","active").eq("license_type","trial_24h").gt("expires_at",new Date().toISOString())
    .select("id,status,owner_email,license_type,expires_at,activated_at").maybeSingle();
   if(error)throw error;if(!data)return reply(req,{ok:false,error:"لایسنس در همین لحظه منقضی یا تغییر کرده است؛ فهرست را تازه‌سازی کنید"},409);
   await log(db,"upgrade_to_permanent",id,"active","active");
   return reply(req,{ok:true,license:data,message:"لایسنس به دائمی ارتقا یافت؛ دسترسی حساب و دستگاه حفظ شد."});
  }
  if(body.action==="list"){
   const now=new Date().toISOString();
   const {error:expireError}=await db.from("factori_license_keys").update({status:"expired"}).in("status",["unused","active"]).not("expires_at","is",null).lte("expires_at",now);
   if(expireError)throw expireError;
   const [rows,total,unused,active,revoked,expired]=await Promise.all([
    db.from("factori_license_keys").select("id,status,created_at,activated_at,revoked_at,order_id,payment_reference,payment_gateway,amount_paid_toman,owner_email,license_type,expires_at").order("created_at",{ascending:false}).limit(500),
    count(db),count(db,"unused"),count(db,"active"),count(db,"revoked"),count(db,"expired")
   ]);
   if(rows.error)throw rows.error;return reply(req,{ok:true,licenses:rows.data||[],stats:{total,unused,active,revoked,expired}});
  }
  if(body.action==="revoke"){
   const id=String(body.id??"");const {data:before,error:readError}=await db.from("factori_license_keys").select("id,status").eq("id",id).maybeSingle();
   if(readError)throw readError;if(!before||!["unused","active"].includes(before.status))return reply(req,{ok:false,error:"این لایسنس وجود ندارد یا قابل لغو نیست"},409);
   const {data,error}=await db.from("factori_license_keys").update({status:"revoked",revoked_at:new Date().toISOString()}).eq("id",id).in("status",["unused","active"]).select("id,status,revoked_at").maybeSingle();
   if(error)throw error;if(!data)return reply(req,{ok:false,error:"وضعیت لایسنس تغییر کرده است؛ بروزرسانی کنید"},409);
   await log(db,"revoke",id,before.status,"revoked");return reply(req,{ok:true,license:data});
  }
  if(body.action==="events"){
   const {data,error}=await db.from("factori_license_admin_events").select("id,license_id,action,previous_status,new_status,created_at").order("created_at",{ascending:false}).limit(50);
   if(error)throw error;return reply(req,{ok:true,events:data||[]});
  }
  return reply(req,{ok:false,error:"عملیات نامعتبر است"},400);
 }catch(e){return reply(req,{ok:false,error:String((e as Error).message??e)},500)}
});