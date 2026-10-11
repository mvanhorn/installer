#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

APKTOOL="${APKTOOL:-apktool}"
KS="${KS:-june_apk_sign.p12}"

"$APKTOOL" b . -o OvenLight_unsigned.apk
jarsigner -keystore "$KS" -storetype PKCS12 -storepass june \
  -sigalg SHA256withRSA -digestalg SHA-256 OvenLight_unsigned.apk june
cp OvenLight_unsigned.apk OvenLight_signed.apk
sha256sum OvenLight_signed.apk
echo "OK -> OvenLight_signed.apk"
