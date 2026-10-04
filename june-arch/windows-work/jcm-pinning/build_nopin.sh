#!/usr/bin/env bash
# Rebuild the oven JuneCloudMessaging.apk with cert pinning neutralized.
# Run on Linux/WSL with java + python3 + apktool.jar.
set -euo pipefail
cd "$(dirname "$0")"

SRC="${1:?usage: build_nopin.sh /path/to/JuneCloudMessaging.apk}"
APKTOOL="${APKTOOL:-apktool.jar}"
KS="${KS:-june_apk_sign.p12}"

rm -rf decoded
java -jar "$APKTOOL" d -f -o decoded "$SRC"
python3 patch.py decoded
java -jar "$APKTOOL" b decoded -o jcm_nopin_unsigned.apk
jarsigner -keystore "$KS" -storetype PKCS12 -storepass june \
  -sigalg SHA256withRSA -digestalg SHA-256 jcm_nopin_unsigned.apk june
cp jcm_nopin_unsigned.apk JuneCloudMessaging_nopin_signed.apk
sha256sum JuneCloudMessaging_nopin_signed.apk
echo "OK -> JuneCloudMessaging_nopin_signed.apk"
