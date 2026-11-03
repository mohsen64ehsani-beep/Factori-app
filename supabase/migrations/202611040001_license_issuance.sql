-- Factoori paid-order license issuance metadata.
-- Safe additive migration: does not alter activation RPCs or existing license rows.
ALTER TABLE public.factori_license_keys
  ADD COLUMN IF NOT EXISTS order_id text,
  ADD COLUMN IF NOT EXISTS encrypted_key text,
  ADD COLUMN IF NOT EXISTS payment_reference text,
  ADD COLUMN IF NOT EXISTS payment_gateway text,
  ADD COLUMN IF NOT EXISTS amount_paid_toman bigint,
  ADD COLUMN IF NOT EXISTS payment_verified_at timestamptz;

CREATE UNIQUE INDEX IF NOT EXISTS factori_license_keys_order_id_uidx
  ON public.factori_license_keys (order_id)
  WHERE order_id IS NOT NULL;

COMMENT ON COLUMN public.factori_license_keys.order_id IS
  'Unique Factoori WordPress order identifier; populated only after verified payment.';
COMMENT ON COLUMN public.factori_license_keys.encrypted_key IS
  'AES-GCM encrypted license key for safe idempotent recovery by the trusted server.';
COMMENT ON COLUMN public.factori_license_keys.payment_reference IS
  'Payment transaction reference verified by the payment gateway server-to-server.';
COMMENT ON COLUMN public.factori_license_keys.amount_paid_toman IS
  'Verified amount in toman.';
COMMENT ON COLUMN public.factori_license_keys.payment_verified_at IS
  'Timestamp when the trusted payment callback was verified.';
