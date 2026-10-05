# MediaCapturer no-pin patch

`MediaCapturer.apk` embeds the same June certificate pinning as
`JuneCloudMessaging` and `Remotes`. On a june-local oven it records a
rectified JPEG once per second while a cook is active and uploads it to
`POST /1/videos/{sessionId}/start_image`; the stock pin rejects june-local's
project-CA leaf, so those frames are recorded and then thrown away.

`build_nopin.sh` decodes the healthy-build APK, applies the shared
`../jcm-pinning/patch.py` (empty certificate pinner plus system-trust-only
`PinningTrustManager`), rebuilds it, and signs it with the project APK key.
The installer stages the signed APK into the encrypted collector at
`/system/priv-app/MediaCapturer/MediaCapturer.apk`, the same way it stages
the JCM and Remotes no-pin APKs.

The APK itself is June-licensed material and is intentionally not published
in the source repository; keep the signed output with the other installer
payload assets.
