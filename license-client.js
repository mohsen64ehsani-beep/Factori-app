import LicenseManager from 'capacitor-license-manager';
import { Capacitor } from '@capacitor/core';

const SUPABASE_URL = 'https://rtlwztotaolbnjdtsjqy.supabase.co';
const SUPABASE_KEY = 'sb_publishable_yQrRq-3DoEWXlf0DOgXExA_sLWKKWrF';

const PUBLIC_JWK = {
  kty: 'EC',
  crv: 'P-256',
  x: '_r1Nk5fzHPiAWAIVp5U9i9eg-3NY0WetWIctLudfAfw',
  y: '3PV_mnmE9xxwwB44ooFJxteuEmfE2POLhwiBQQah8uQ',
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

async function native(progress = () => {}) {
  progress('بررسی پلتفرم اجرای برنامه');
  const platform = Capacitor.getPlatform?.();
  if (platform !== 'android') {
    throw new Error('پلتفرم اندروید شناسایی نشد: ' + String(platform || 'unknown'));
  }

  progress('بررسی ثبت افزونه LicenseManager در اندروید');
  if (typeof Capacitor.isPluginAvailable === 'function' &&
      !Capacitor.isPluginAvailable('LicenseManager')) {
    throw new Error('افزونه LicenseManager داخل APK ثبت نشده است؛ APK باید دوباره با افزونه همگام‌سازی شود.');
  }

  const methods = ['getPublicKey', 'signNonce', 'saveToken', 'getToken'];
  for (const method of methods) {
    progress('بررسی متد افزونه: ' + method);
    if (typeof LicenseManager?.[method] !== 'function') {
      throw new Error('متد ' + method + ' در افزونه LicenseManager ثبت نشده است.');
    }
  }

  progress('افزونه اندروید شناسایی شد');
}

async function isLicensed() {
  try {
    await native();
    const device = await LicenseManager.getPublicKey();
    const stored = await LicenseManager.getToken();

    return !!stored.token &&
      await verifyToken(stored.token, device.thumbprint);
  } catch {
    return false;
  }
}

async function activate(licenseKey, onProgress) {
  let stage = 'آماده‌سازی افزونه اندروید';
  const progress = value => { stage = value; try { onProgress?.(value); } catch {} };
  progress(stage);

  const timed = (promise, label, ms = 15000) => Promise.race([
    promise,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error('TIMEOUT: ' + label)), ms)
    )
  ]);

  try {
    progress('افزونه آماده شد؛ ورود به مرحله ارتباط با سرور');
    await native(progress);
    progress('افزونه آماده است؛ آماده‌سازی درخواست امنیتی');
    const plugin = LicenseManager;

    const call = async body => {
      progress(body.action === 'issue_nonce'
        ? 'ارتباط با سرور و دریافت کد امنیتی'
        : 'ارسال درخواست فعال‌سازی به سرور');

      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 15000);

      try {
        const res = await fetch(
          SUPABASE_URL + '/functions/v1/activate-license',
          {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              'apikey': SUPABASE_KEY,
              'Authorization': 'Bearer ' + SUPABASE_KEY
            },
            body: JSON.stringify(body),
            signal: controller.signal
          }
        );

        const raw = await res.text();
        let data = {};

        try {
          data = raw ? JSON.parse(raw) : {};
        } catch {}

        if (!res.ok || !data.ok) {
          throw new Error(
            data.reason || (data.error === 'server_error' && data.detail
              ? 'خطای داخلی سرور: ' + data.detail
              : data.error) ||
            ('خطای سرور: HTTP ' + res.status)
          );
        }

        return data;
      } catch (error) {
        if (error.name === 'AbortError') {
          throw new Error('پاسخ سرور در ۱۵ ثانیه دریافت نشد.');
        }
        throw error;
      } finally {
        clearTimeout(timer);
      }
    };

    const n = await timed(
      call({ action: 'issue_nonce' }),
      'ارتباط با سرور و دریافت کد امنیتی',
      18000
    );

    if (!n.nonce) {
      throw new Error('دریافت کد امنیتی ناموفق بود.');
    }

    progress('خواندن کلید امن دستگاه');
    // اولین ساخت کلید در Android Keystore ممکن است روی بعضی گوشی‌ها بیشتر طول بکشد.
    const device = await timed(plugin.getPublicKey(), stage, 45000);

    progress('امضای کد امنیتی در دستگاه');
    const signed = await timed(
      plugin.signNonce({ nonce: n.nonce }),
      stage
    );

    const result = await timed(
      call({
        action: 'activate',
        licenseKey,
        nonce: n.nonce,
        signature: signed.signature,
        deviceJwk: device.jwk
      }),
      'ارسال درخواست فعال‌سازی',
      18000
    );

    progress('بررسی مجوز دریافتی');

    if (!await timed(
      verifyToken(result.token, device.thumbprint),
      stage
    )) {
      throw new Error('اعتبار مجوز صادرشده تأیید نشد.');
    }

    progress('ذخیره مجوز روی دستگاه');

    await timed(
      plugin.saveToken({ token: result.token }),
      stage
    );

    return { ok: true };

  } catch (error) {
    console.error('[Factori License]', stage, error);

    throw new Error(
      stage + ': ' + (error?.message || String(error))
    );
  }
}

async function getLicenseAuthToken() {
  await native();
  const device = await LicenseManager.getPublicKey();
  const stored = await LicenseManager.getToken();
  if (!stored?.token || !await verifyToken(stored.token, device.thumbprint)) {
    throw new Error('لایسنس معتبر برای احراز هویت پیامک پیدا نشد.');
  }
  return stored.token;
}

window.FactoriLicenseApi = { isLicensed, activate, getLicenseAuthToken };
window.dispatchEvent(new Event('factori-license-ready'));
