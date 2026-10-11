#!/usr/bin/env bash
# Rebuild Analytics.apk with certificate pinning neutralized.
# Run with java + python3 + apktool available.
set -euo pipefail
cd "$(dirname "$0")"

SRC="${1:-${ANALYTICS_SRC:?usage: build_nopin.sh /path/to/Analytics.apk}}"
APKTOOL="${APKTOOL:-apktool}"
KS="${KS:-june_apk_sign.p12}"

rm -rf decoded
"$APKTOOL" d -f -o decoded "$SRC"
python3 ../jcm-pinning/patch.py decoded
"$APKTOOL" b decoded -o Analytics_nopin_unsigned.apk
jarsigner -keystore "$KS" -storetype PKCS12 -storepass june \
  -sigalg SHA256withRSA -digestalg SHA-256 \
  Analytics_nopin_unsigned.apk june
cp Analytics_nopin_unsigned.apk Analytics_nopin_signed.apk
sha256sum Analytics_nopin_signed.apk
echo "OK -> Analytics_nopin_signed.apk"
