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

## Optional token fallback (bench-gated, UNPROVEN — do not ship yet)

Layer A1 from `docs/identity-generation.md` / `docs/jcm-token-fallback.md`: make the
already-patched JCM keep a non-null `Authorization` header when AccountManager has no
June account. `DeferredAuthTokenHolder.getAuthToken()/forceRefresh()` and
`AuthDecorator.ensureLatestHeaders(String)` fall back to
`SystemProperties.get("june.local.token")`, then `account.token` in
`/data/june/identity.json`, then a compiled-in `v2:` token. **AccountManager is still
tried first**, so a normal oven is unaffected.

Build it as a separate artifact on the Arch host (never overwrite the shipped APK):

```bash
bash build_nopin.sh /path/to/JuneCloudMessaging.apk --token-fallback
# -> JuneCloudMessaging_nopin_fallback_signed.apk
```

This is **bench-only** until the P4 test in `docs/jcm-token-fallback.md` passes: if the
JCM has an additional account-presence gate, the fallback alone will not open the socket.
Do not copy this APK into the live ISO payload (`prepare_assets.sh`) or ship it before
that test.

The fallback smali is generated from string templates, where a wrong `if-eqz`/`if-nez`
polarity silently breaks the order (the first revision had exactly that bug). Run the
interpreter-based regression test after any edit:

```bash
python3 test_patch.py     # python3 only; no java/apktool/oven needed
```

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