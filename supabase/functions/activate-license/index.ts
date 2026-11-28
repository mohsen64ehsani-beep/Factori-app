import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { importJWK, SignJWT } from "https://esm.sh/jose@5";
const cors=(req:Request)=>({"Access-Control-Allow-Origin":req.headers.get("origin")??"*","Access-Control-Allow-Headers":req.headers.get("access-control-request-headers")??"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Access-Control-Max-Age":"86400","Vary":"Origin, Access-Control-Request-Headers","Content-Type":"application/json","Cache-Control":"no-store"});
const reply=(req:Request,data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers:cors(req)});
const hex=(b:Uint8Array)=>Array.from(b,x=>x.toString(16).padStart(2,"0")).join("");
const hash=async(s:string)=>hex(new Uint8Array(await crypto.subtle.digest("SHA-256",new TextEncoder().encode(s))));
const decode=(s:string)=>{const v=s.replace(/-/g,"+").replace(/_/g,"/");const raw=atob(v+"=".repeat((4-v.length%4)%4));return Uint8Array.from(raw,c=>c.charCodeAt(0))};
async function signLicenseToken(license:any,activationId:string,thumbprint:string){
 const privateText=Deno.env.get("FACTORY_LICENSE_SIGNING_PRIVATE_JWK");if(!privateText)throw new Error("Signing key missing");
 let privateJwk:Record<string,unknown>;try{privateJwk=JSON.parse(privateText)}catch{throw new Error("Signing key configuration is not valid JSON")}
 const signingKey=await importJWK(privateJwk,"ES256"),now=Math.floor(Date.now()/1000);
 let jwt=new SignJWT({device:thumbprint,permanent:!license.expires_at,license_type:license.license_type??"permanent"})
  .setProtectedHeader({alg:"ES256",typ:"JWT"}).setIssuer("factori-license").setAudience("com.factori.app").setSubject(activationId).setIssuedAt(now);
 if(license.expires_at)jwt=jwt.setExpirationTime(Math.floor(Date.parse(license.expires_at)/1000));
 return await jwt.sign(signingKey);
}
Deno.serve(async req=>{
 if(req.method==="OPTIONS")return new Response(null,{status:204,headers:cors(req)});
 if(req.method!=="POST")return reply(req,{ok:false},405);
 try{
  const url=Deno.env.get("SUPABASE_URL"),serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if(!url||!serviceKey)throw new Error("Supabase config missing");
  const admin=createClient(url,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
  const body=await req.json();
  if(body.action==="check_status"){
   const activationId=String(body.activation_id??""),thumbprint=String(body.device_thumbprint??"");
   if(!/^[0-9a-f-]{36}$/i.test(activationId)||thumbprint.length<20||thumbprint.length>200)return reply(req,{ok:false,error:"invalid_request"},400);
   const {data,error}=await admin.from("factori_license_activations").select("id,device_thumbprint,factori_license_keys!inner(id,status,expires_at,license_type)").eq("id",activationId).eq("device_thumbprint",thumbprint).maybeSingle();
   if(error)throw error;if(!data)return reply(req,{ok:true,active:false,reason:"activation_not_found"});
   const license=(data as any).factori_license_keys;
   if(license.expires_at&&Date.parse(license.expires_at)<=Date.now()){
    if(["unused","active"].includes(license.status)){const {error:updateError}=await admin.from("factori_license_keys").update({status:"expired"}).eq("id",license.id).in("status",["unused","active"]);if(updateError)throw updateError;}
    return reply(req,{ok:true,active:false,reason:"expired"});
   }
   if(license.status!=="active")return reply(req,{ok:true,active:false,reason:license.status});
   const token=await signLicenseToken(license,activationId,thumbprint);
   return reply(req,{ok:true,active:true,license_type:license.license_type??"permanent",expires_at:license.expires_at??null,token});
  }
  if(body.action==="issue_nonce"){const {data,error}=await admin.rpc("factori_issue_nonce");if(error)throw error;return reply(req,{ok:true,nonce:data});}
  if(body.action!=="activate")return reply(req,{ok:false,error:"invalid_action"},400);
  const licenseKey=String(body.licenseKey??"").trim(),nonce=String(body.nonce??""),signature=String(body.signature??""),jwk=body.deviceJwk;
  if(!licenseKey||!nonce||!signature||jwk?.kty!=="EC"||jwk?.crv!=="P-256"||typeof jwk.x!=="string"||typeof jwk.y!=="string"||"d" in jwk)return reply(req,{ok:false,error:"invalid_request"},400);
  let email=String(body.email??"").trim().toLowerCase();
  if(!email){const authHeader=req.headers.get("authorization")||"";if(authHeader.toLowerCase().startsWith("bearer ")){const {data,error}=await admin.auth.getUser(authHeader.slice(7));if(!error&&data.user?.email)email=data.user.email.trim().toLowerCase();}}
  const keyHash=await hash(licenseKey);
  const {data:license,error:licenseError}=await admin.from("factori_license_keys").select("id,status,owner_email,license_type,expires_at").eq("key_hash",keyHash).maybeSingle();
  if(licenseError)throw licenseError;if(!license)return reply(req,{ok:false,reason:"invalid"},403);
  if(license.expires_at&&Date.parse(license.expires_at)<=Date.now()){
   if(["unused","active"].includes(license.status)){const {error:updateError}=await admin.from("factori_license_keys").update({status:"expired"}).eq("id",license.id).in("status",["unused","active"]);if(updateError)throw updateError;}
   return reply(req,{ok:false,reason:"expired"},403);
  }
  if(license.status!=="unused")return reply(req,{ok:false,reason:license.status},403);
  if(license.owner_email){if(!email)return reply(req,{ok:false,reason:"assigned_email_required"},400);if(email!==String(license.owner_email).trim().toLowerCase())return reply(req,{ok:false,reason:"email_mismatch"},403);}
  const publicKey=await crypto.subtle.importKey("jwk",{kty:"EC",crv:"P-256",x:jwk.x,y:jwk.y,ext:true},{name:"ECDSA",namedCurve:"P-256"},false,["verify"]);
  const valid=await crypto.subtle.verify({name:"ECDSA",hash:"SHA-256"},publicKey,decode(signature),new TextEncoder().encode(nonce));
  if(!valid)return reply(req,{ok:false,error:"invalid_device_signature"},401);
  const canonical=JSON.stringify({crv:"P-256",kty:"EC",x:jwk.x,y:jwk.y});
  const thumbprint=btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.digest("SHA-256",new TextEncoder().encode(canonical))))).split("+").join("-").split("/").join("_").replace(/=+$/g,"");
  const {data,error}=await admin.rpc("factori_consume_license",{p_key_hash:keyHash,p_device_jwk:{kty:"EC",crv:"P-256",x:jwk.x,y:jwk.y},p_device_thumbprint:thumbprint,p_nonce_hash:await hash(nonce)});
  if(error)throw error;if(!data?.ok)return reply(req,{ok:false,reason:data?.reason??"activation_failed"},403);
  const token=await signLicenseToken(license,data.activation_id,thumbprint);
  return reply(req,{ok:true,token,activation_id:data.activation_id,license_type:license.license_type??"permanent",expires_at:license.expires_at??null});
 }catch(e){return reply(req,{ok:false,error:"server_error",detail:String((e as Error)?.message??e)},500)}
});