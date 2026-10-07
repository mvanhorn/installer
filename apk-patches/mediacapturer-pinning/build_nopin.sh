#!/usr/bin/env bash
# Rebuild MediaCapturer.apk with certificate pinning neutralized.
# Run with java + python3 + apktool available.
set -euo pipefail
cd "$(dirname "$0")"

SRC="${1:-${MEDIACAPTURER_SRC:-/home/fng/nas2/gene/Programming/June/local-resources/june-rcm/healthy-build/decompiled/priv-app-apks/MediaCapturer.apk}}"
APKTOOL="${APKTOOL:-/home/fng/.local/bin/apktool}"
KS="${KS:-/home/fng/nas2/gene/Programming/June/tools/certs/june_apk_sign.p12}"

rm -rf decoded
"$APKTOOL" d -f -o decoded "$SRC"
python3 ../jcm-pinning/patch.py decoded
"$APKTOOL" b decoded -o MediaCapturer_nopin_unsigned.apk
jarsigner -keystore "$KS" -storetype PKCS12 -storepass june \
  -sigalg SHA256withRSA -digestalg SHA-256 \
  MediaCapturer_nopin_unsigned.apk june
cp MediaCapturer_nopin_unsigned.apk MediaCapturer_nopin_signed.apk
sha256sum MediaCapturer_nopin_signed.apk
echo "OK -> MediaCapturer_nopin_signed.apk"
