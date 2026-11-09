import { App } from '@capacitor/app';

if (window.Capacitor?.isNativePlatform?.()) {
  window.factoriExitApp = () => App.exitApp();
  App.addListener('backButton', () => {
    if (typeof window.factoriBackStep === 'function') window.factoriBackStep();
  });
}
