# Factoori paid-order license issuance

This function is intentionally separate from `activate-license`. It does not change the existing activation RPCs, nonce flow, device thumbprint calculation, or ES256 token format.

## Required database migration

Apply `supabase/migrations/202611040001_license_issuance.sql` before deploying this function. It adds nullable payment/idempotency metadata and a unique index on `order_id`.

## Required Supabase secrets

Set these server-side secrets:

- `FACTOORI_ISSUE_SECRET`: a high-entropy shared secret used only by the WordPress server.
- `FACTOORI_LICENSE_ENCRYPTION_KEY`: 32 random bytes encoded as unpadded Base64URL. Used to encrypt the recoverable license string with AES-256-GCM.
- `FACTOORI_PRODUCT_PRICE_TOMAN`: `1500000`.

The standard `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` environment variables must also be available to the Edge Function.

Deploy with JWT verification disabled because this endpoint uses its own server-to-server shared-secret header:

```bash
supabase functions deploy issue-license --project-ref rtlwztotaolbnjdtsjqy --no-verify-jwt
```

## Trusted caller contract

Only the WordPress payment callback may call this endpoint, and only after it has verified the transaction directly with the gateway server. It sends:

- `order_id`: stable WordPress order identifier
- `payment_reference`: gateway transaction reference
- `amount_toman`: exactly 1,500,000
- `payment_gateway`: short gateway identifier

It must send `X-Factoori-Issue-Secret` with the shared secret. Never expose this secret in a browser, theme JavaScript, or APK.

## Idempotency and storage

The unique `order_id` index ensures at most one key per order. The plaintext key is AES-GCM encrypted in `encrypted_key` so a trusted callback retry can recover the exact same key if the HTTP response was lost; `key_hash` remains the value used by the existing activation flow. A retry with a different payment reference or amount is rejected.

No payment gateway callback is implemented by this function. The caller must perform real gateway verification first.