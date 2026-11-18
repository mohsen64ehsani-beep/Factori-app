import { verifyP256Proof, toBase64Url } from "./crypto.ts";

Deno.test("P-256 challenge signature accepts the matching private key", async () => {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const publicJwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
  const message = "challenge.nonce.business.device.user";
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(message));
  if (!await verifyP256Proof(publicJwk, message, toBase64Url(signature))) throw new Error("Expected valid device signature to verify");
});

Deno.test("P-256 challenge signature rejects a changed nonce and a private JWK", async () => {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const publicJwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
  const message = "challenge.original-nonce.business.device.user";
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(message));
  if (await verifyP256Proof(publicJwk, message.replace("original-nonce", "replayed-nonce"), toBase64Url(signature))) {
    throw new Error("Changed nonce must not verify");
  }
  if (await verifyP256Proof({ ...publicJwk, d: "private-material" }, message, toBase64Url(signature))) {
    throw new Error("Private JWK must not be accepted as the registered public key");
  }
});
