package com.factori.licensemanager;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.Signature;
import java.security.interfaces.ECPublicKey;
import java.security.spec.ECGenParameterSpec;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

@CapacitorPlugin(name = "LicenseManager")
public class LicenseManagerPlugin extends Plugin {

    private static final String KEY_ALIAS = "factori_device_license_key";
    private static final String AES_ALIAS = "factori_license_storage_key";
    private static final String PREFS = "factori_license_storage";
    private static final String TOKEN_KEY = "license_token";

    private String b64(byte[] data) {
        return Base64.encodeToString(
            data,
            Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING
        );
    }

    private byte[] sha256(byte[] data) throws Exception {
        return MessageDigest.getInstance("SHA-256").digest(data);
    }

    private byte[] fixed32(BigInteger value) {
        byte[] src = value.toByteArray();
        byte[] out = new byte[32];
        int len = Math.min(src.length, 32);
        System.arraycopy(src, src.length - len, out, 32 - len, len);
        return out;
    }

    private KeyPair getOrCreateKeyPair() throws Exception {
        KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
        ks.load(null);

        if (ks.containsAlias(KEY_ALIAS)) {
            java.security.PrivateKey privateKey =
                (java.security.PrivateKey) ks.getKey(KEY_ALIAS, null);
            java.security.PublicKey publicKey =
                ks.getCertificate(KEY_ALIAS).getPublicKey();

            return new KeyPair(publicKey, privateKey);
        }

        KeyPairGenerator generator = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_EC,
            "AndroidKeyStore"
        );

        generator.initialize(
            new KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_SIGN | KeyProperties.PURPOSE_VERIFY
            )
            .setAlgorithmParameterSpec(new ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .build()
        );

        return generator.generateKeyPair();
    }

    private String thumbprint(ECPublicKey key) throws Exception {
        String x = b64(fixed32(key.getW().getAffineX()));
        String y = b64(fixed32(key.getW().getAffineY()));

        String canonical =
            "{\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":\"" +
            x + "\",\"y\":\"" + y + "\"}";

        return b64(sha256(canonical.getBytes(StandardCharsets.UTF_8)));
    }

    @PluginMethod
    public void getPublicKey(PluginCall call) {
        try {
            KeyPair pair = getOrCreateKeyPair();
            ECPublicKey key = (ECPublicKey) pair.getPublic();

            String x = b64(fixed32(key.getW().getAffineX()));
            String y = b64(fixed32(key.getW().getAffineY()));

            JSObject jwk = new JSObject();
            jwk.put("kty", "EC");
            jwk.put("crv", "P-256");
            jwk.put("x", x);
            jwk.put("y", y);

            JSObject result = new JSObject();
            result.put("jwk", jwk);
            result.put("thumbprint", thumbprint(key));

            call.resolve(result);
        } catch (Exception e) {
            call.reject("خطا در ساخت کلید دستگاه", e);
        }
    }

    @PluginMethod
    public void signNonce(PluginCall call) {
        try {
            String nonce = call.getString("nonce");
            if (nonce == null || nonce.isEmpty()) {
                call.reject("Nonce نامعتبر است");
                return;
            }

            KeyPair pair = getOrCreateKeyPair();

            Signature signer = Signature.getInstance("SHA256withECDSA");
            signer.initSign(pair.getPrivate());
            signer.update(nonce.getBytes(StandardCharsets.UTF_8));

            byte[] der = signer.sign();
            byte[] raw = derToRaw(der);

            JSObject result = new JSObject();
            result.put("signature", b64(raw));
            call.resolve(result);

        } catch (Exception e) {
            call.reject("خطا در امضای درخواست", e);
        }
    }

    private byte[] derToRaw(byte[] der) throws Exception {
        int offset = 2;

        if ((der[1] & 0x80) != 0) {
            offset = 2 + (der[1] & 0x7f);
        }

        if (der[offset] != 0x02) throw new Exception("Invalid signature");
        int rLen = der[offset + 1] & 0xff;
        byte[] r = new byte[rLen];
        System.arraycopy(der, offset + 2, r, 0, rLen);

        int sOffset = offset + 2 + rLen;
        if (der[sOffset] != 0x02) throw new Exception("Invalid signature");
        int sLen = der[sOffset + 1] & 0xff;
        byte[] s = new byte[sLen];
        System.arraycopy(der, sOffset + 2, s, 0, sLen);

        byte[] raw = new byte[64];
        copyInteger(r, raw, 0);
        copyInteger(s, raw, 32);
        return raw;
    }

    private void copyInteger(byte[] src, byte[] dest, int position) {
        int start = src.length > 32 ? src.length - 32 : 0;
        int len = Math.min(src.length, 32);
        System.arraycopy(src, start, dest, position + 32 - len, len);
    }

    private SecretKey getStorageKey() throws Exception {
        KeyStore ks = KeyStore.getInstance("AndroidKeyStore");
        ks.load(null);

        if (ks.containsAlias(AES_ALIAS)) {
            return ((KeyStore.SecretKeyEntry)
                ks.getEntry(AES_ALIAS, null)).getSecretKey();
        }

        KeyGenerator generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore"
        );

        generator.init(
            new KeyGenParameterSpec.Builder(
                AES_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT
            )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .build()
        );

        return generator.generateKey();
    }

    @PluginMethod
    public void saveToken(PluginCall call) {
        try {
            String token = call.getString("token");
            if (token == null || token.isEmpty()) {
                call.reject("توکن نامعتبر است");
                return;
            }

            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, getStorageKey());

            byte[] encrypted = cipher.doFinal(
                token.getBytes(StandardCharsets.UTF_8)
            );

            byte[] iv = cipher.getIV();
            byte[] packed = new byte[iv.length + encrypted.length];

            System.arraycopy(iv, 0, packed, 0, iv.length);
            System.arraycopy(encrypted, 0, packed, iv.length, encrypted.length);

            SharedPreferences prefs = getContext().getSharedPreferences(
                PREFS, Context.MODE_PRIVATE
            );

            prefs.edit().putString(TOKEN_KEY, b64(packed)).apply();
            call.resolve();

        } catch (Exception e) {
            call.reject("خطا در ذخیره لایسنس", e);
        }
    }

    @PluginMethod
    public void getToken(PluginCall call) {
        try {
            SharedPreferences prefs = getContext().getSharedPreferences(
                PREFS, Context.MODE_PRIVATE
            );

            String stored = prefs.getString(TOKEN_KEY, null);
            JSObject result = new JSObject();

            if (stored == null) {
                result.put("token", JSObject.NULL);
                call.resolve(result);
                return;
            }

            byte[] packed = Base64.decode(
                stored, Base64.URL_SAFE | Base64.NO_WRAP
            );

            byte[] iv = new byte[12];
            byte[] encrypted = new byte[packed.length - 12];

            System.arraycopy(packed, 0, iv, 0, 12);
            System.arraycopy(packed, 12, encrypted, 0, encrypted.length);

            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(
                Cipher.DECRYPT_MODE,
                getStorageKey(),
                new GCMParameterSpec(128, iv)
            );

            String token = new String(
                cipher.doFinal(encrypted),
                StandardCharsets.UTF_8
            );

            result.put("token", token);
            call.resolve(result);

        } catch (Exception e) {
            call.reject("خطا در خواندن لایسنس", e);
        }
    }

    @PluginMethod
    public void clearToken(PluginCall call) {
        getContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().remove(TOKEN_KEY).apply();
        call.resolve();
    }
          }
