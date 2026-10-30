import LicenseManager from 'capacitor-license-manager';

const SUPABASE_URL = 'https://rtlwztotaolbnjdtsjqy.supabase.co';
const SUPABASE_KEY = 'sb_publishable_yQrRq-3DoEWXlf0DOgXExA_sLWKKWrF';

const PUBLIC_JWK = {
  kty: 'EC',
  crv: 'P-256',
  x: 'r5HwE6vyPGziWtca6IP1eDmj2kkQDziu81MvZq5cXaE',
  y: 'gAzNBUJUWhODplpa7mBdAMxyTuIJCF-u9k2UPkNKEus',
  ext: true
};

const b64u = s => {
  const t = s.replace(/-/g, '+').replace(/_/g, '/');
  const raw = atob(t + '='.repeat((4 - t.length % 4) % 4));
  return Uint8Array.from(raw, c => c.charCodeAt(0));
};

async function verifyToken(token, thumbprint) {
  if (!token || typeof token !== 'string') return false;
  const p = token.split('.');
  if (p.length !== 3) return false;

  let header, claims;
  try {
    header = JSON.parse(new TextDecoder().decode(b64u(p[0])));
    claims = JSON.parse(new TextDecoder().decode(b64u(p[1])));
  } catch {
    return false;
  }

  if (
    header.alg !== 'ES256' ||
    header.typ !== 'JWT' ||
    claims.iss !== 'factori-license' ||
    claims.aud !== 'com.factori.app' ||
    claims.device !== thumbprint ||
    claims.permanent !== true ||
    !claims.sub ||
    !Number.isFinite(claims.iat)
  ) return false;

  try {
    const key = await crypto.subtle.importKey(
      'jwk',
      PUBLIC_JWK,
      { name: 'ECDSA', namedCurve: 'P-256' },
      false,
      ['verify']
    );

    return await crypto.subtle.verify(
      { name: 'ECDSA', hash: 'SHA-256' },
      key,
      b64u(p[2]),
      new TextEncoder().encode(p[0] + '.' + p[1])
    );
  } catch {
    return false;
  }
}

async function native() {
  if (!window.Capacitor?.isNativePlatform?.()) {
    throw new Error('فعال‌سازی فقط در نسخه اندروید امکان‌پذیر است.');
  }
  return LicenseManager;
}

async function isLicensed() {
  try {
    const plugin = await native();
    const device = await plugin.getPublicKey();
    const stored = await plugin.getToken();

    return !!stored.token &&
      await verifyToken(stored.token, device.thumbprint);
  } catch {
    return false;
  }
}

async function activate(licenseKey) {
  const plugin = await native();

  const call = async body => {
    const res = await fetch(
      SUPABASE_URL + '/functions/v1/activate-license',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'apikey': SUPABASE_KEY,
          'Authorization': 'Bearer ' + SUPABASE_KEY
        },
        body: JSON.stringify(body)
      }
    );

    const data = await res.json().catch(() => ({}));

    if (!res.ok || !data.ok) {
      throw new Error(data.reason || data.error || 'کد لایسنس معتبر نیست.');
    }

    return data;
  };

  const n = await call({ action: 'issue_nonce' });
  if (!n.nonce) throw new Error('دریافت کد امنیتی ناموفق بود.');

  const device = await plugin.getPublicKey();
  const signed = await plugin.signNonce({ nonce: n.nonce });

  const result = await call({
    action: 'activate',
    licenseKey,
    nonce: n.nonce,
    signature: signed.signature,
    deviceJwk: device.jwk
  });

  if (!await verifyToken(result.token, device.thumbprint)) {
    throw new Error('اعتبار مجوز صادرشده تأیید نشد.');
  }

  await plugin.saveToken({ token: result.token });
  return { ok: true };
}

window.FactoriLicenseApi = { isLicensed, activate };
