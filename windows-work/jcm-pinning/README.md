# JuneCloudMessaging.apk — pinning neutralized (system trust only)

Source: `june-rcm/healthy-build/decrypted-priv-app/JuneCloudMessaging.apk`
(factory clean, hostname endpoints `api/messaging.junelife.com`).

## Exact smali edits
1. `com/junelife/android/networkclient/HttpClientFactory.smali`
   - `createCertificatePinner()` now returns an EMPTY `CertificatePinner`
     (`new Builder().build()`), so `createOkHttpClient()` installs zero pins.
2. `com/junelife/android/networkclient/PinningTrustManager.smali`
   - `checkServerTrusted(...)` now delegates to the default/system
     `TrustManagerFactory` (`X509` + null KeyStore) via
     `X509TrustManager.checkServerTrusted(chain, authType)`. No pin list is
     consulted, so validation is pure chain-to-system-trust-anchor.
   - `checkClientTrusted(...)` is now a no-op (`return-void`).

Endpoint hostnames were NOT changed.

## Build
```bash
bash build_nopin.sh
```
Requires `java`, `python3`, `apktool.jar`, and `june_apk_sign.p12` (alias `june`,
password `june`). The rebuilt APK is signed with the project key using
`jarsigner` (v1 JAR signature — sufficient for the oven's Android 5.0.1).

## Artifact
- `JuneCloudMessaging_nopin_signed.apk`
- SHA256: 830a5eb4c371c3d7b4c88a261a14504ab18427d7857cdc1ada9f24fea5cd8054

Install the patched APK via the existing EncFS/system-image or provisioning-SOS
route (see `docs/encfs-rewrap-runbook.md` and `tools/orchestrator/`).