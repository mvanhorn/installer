# Analytics no-pin patch

The oven-side `Analytics` system app embeds the same June certificate pinning
as the other oven apps. On a june-local oven its uploads are rejected by the
pin and it retries roughly every second, producing constant TLS noise and CPU
wakeups even though the data has nowhere to go.

`build_nopin.sh` decodes the healthy-build APK, applies the shared
`../jcm-pinning/patch.py` (empty certificate pinner plus system-trust-only
`PinningTrustManager`), rebuilds it, and signs it with the project APK key.
The installer replaces `/system/app/Analytics/Analytics.apk` with this signed
copy; analytics is not used for cooking, so the only effect is a quiet oven.

The APK itself is June-licensed material and is intentionally not published
in the source repository; keep the signed output with the other installer
payload assets.
