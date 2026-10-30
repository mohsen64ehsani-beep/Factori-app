import type { PluginListenerHandle } from '@capacitor/core';

export interface DeviceJwk {
  kty: 'EC';
  crv: 'P-256';
  x: string;
  y: string;
}

export interface LicenseManagerPlugin {
  getPublicKey(): Promise<{ jwk: DeviceJwk; thumbprint: string }>;
  signNonce(options: { nonce: string }): Promise<{ signature: string }>;
  saveToken(options: { token: string }): Promise<void>;
  getToken(): Promise<{ token: string | null }>;
  clearToken(): Promise<void>;
}

declare const LicenseManager: LicenseManagerPlugin;
export default LicenseManager;
