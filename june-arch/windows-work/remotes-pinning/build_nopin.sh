#!/usr/bin/env bash
# Rebuild Remotes.apk with cert pinning neutralized (system trust only).
# Usage: bash build_nopin.sh /path/to/factory/Remotes.apk
set -euo pipefail
cd "$(dirname "$0")"

SRC="${1:?usage: build_nopin.sh /path/to/Remotes.apk}"
APKTOOL="${APKTOOL:-apktool.jar}"
KS="${KS:-june_apk_sign.p12}"
PATCH="${PATCH:-../jcm-pinning/patch.py}"

rm -rf decoded
java -jar "$APKTOOL" d -f -o decoded "$SRC"
python3 "$PATCH" decoded
java -jar "$APKTOOL" b decoded -o Remotes_nopin_unsigned.apk
jarsigner -keystore "$KS" -storetype PKCS12 -storepass june \
  -sigalg SHA256withRSA -digestalg SHA-256 Remotes_nopin_unsigned.apk june
cp Remotes_nopin_unsigned.apk Remotes_nopin_signed.apk
sha256sum Remotes_nopin_signed.apk
echo "OK -> Remotes_nopin_signed.apk"
