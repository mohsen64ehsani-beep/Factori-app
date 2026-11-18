export function fromBase64Url(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

export function toBase64Url(bytes: ArrayBuffer): string {
  let binary = "";
  for (const byte of new Uint8Array(bytes)) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

export function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const buffer = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buffer).set(bytes);
  return buffer;
}

export function encodeText(value: string): ArrayBuffer {
  return toArrayBuffer(new TextEncoder().encode(value));
}

export function toHex(bytes: ArrayBuffer): string {
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function verifyP256Proof(jwk: JsonWebKey, message: string, signature: string): Promise<boolean> {
  if (jwk.kty !== "EC" || jwk.crv !== "P-256" || jwk.d || !jwk.x || !jwk.y
    || !/^[A-Za-z0-9_-]{86}$/.test(signature)) return false;
  try {
    const publicKey = await crypto.subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    return await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" }, publicKey, toArrayBuffer(fromBase64Url(signature)), encodeText(message),
    );
  } catch { return false; }
}
