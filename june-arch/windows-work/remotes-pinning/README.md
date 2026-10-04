# Remotes.apk — cert pinning neutralized (system trust only)

Source: `Remotes.apk` pulled from the oven (`/system/priv-app/Remotes/Remotes.apk`,
this is the app that runs the oven-side pairing UI, `PairingV2Activity`).

The app embeds the same `com.junelife.android.networkclient` library as
JuneCloudMessaging, including `HttpClientFactory.createCertificatePinner()`
with hardcoded SHA-1 pins for `api.junelife.com`. With a per-home CA the
oven-side pairing request (`/{api_version}/devices/pairing/{pin}/oven`) dies
in pinning, which the user sees as "couldn't connect with that security code".

## Smali edits

Identical to the JCM patch; `../jcm-pinning/patch.py` applies both:

1. `HttpClientFactory.createCertificatePinner()` now returns an empty
   `CertificatePinner` (`new Builder().build()`).
2. `PinningTrustManager.checkServerTrusted(...)` delegates to the default
   system `TrustManagerFactory`; `checkClientTrusted(...)` is a no-op.

Endpoint hostnames are unchanged, so the app still talks to
`api`/`messaging.junelife.com`, which the oven's `/etc/hosts` redirects to the
local server.

## Build

```bash
bash build_nopin.sh /path/to/factory/Remotes.apk
```

Requires `java`, `python3`, `apktool.jar` and the project APK signing key
(`June/tools/certs/june_apk_sign.p12`, alias `june`, password `june`).

## Artifact

- `Remotes_nopin_signed.apk`
- SHA256: 165dfe11897172ddf79c63feaf688578f76903b87244d2b7d6c436871fbd94c4
