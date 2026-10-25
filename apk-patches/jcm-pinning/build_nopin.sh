#!/usr/bin/env bash
# Rebuild the oven JuneCloudMessaging.apk with cert pinning neutralized.
# Run on Linux/WSL with java + python3 + apktool.jar.
#
# Usage:
#   bash build_nopin.sh /path/to/JuneCloudMessaging.apk
#       Shipped pinning patch -> JuneCloudMessaging_nopin_signed.apk
#
#   bash build_nopin.sh /path/to/JuneCloudMessaging.apk --token-fallback
#       Pinning patch + optional layer A1 token fallback
#       -> JuneCloudMessaging_nopin_fallback_signed.apk
#       BENCH-GATED: unproven, do not copy this APK into the shipped assets/
#       payload (or prepare_assets.sh) until the P4 test in
#       docs/jcm-token-fallback.md passes.  See that doc for the edit, build,
#       risk and test procedure.
set -euo pipefail
cd "$(dirname "$0")"

SRC=""
TOKEN_FALLBACK=0
for arg in "$@"; do
  case "$arg" in
    --token-fallback)
      TOKEN_FALLBACK=1
      ;;
    -*)
      echo "unknown option: $arg" >&2
      echo "usage: build_nopin.sh /path/to/JuneCloudMessaging.apk [--token-fallback]" >&2
      exit 2
      ;;
    *)
      if [ -n "$SRC" ]; then
        echo "usage: build_nopin.sh /path/to/JuneCloudMessaging.apk [--token-fallback]" >&2
        exit 2
      fi
      SRC="$arg"
      ;;
  esac
done
if [ -z "$SRC" ]; then
  echo "usage: build_nopin.sh /path/to/JuneCloudMessaging.apk [--token-fallback]" >&2
  exit 2
fi

APKTOOL="${APKTOOL:-apktool.jar}"
KS="${KS:-june_apk_sign.p12}"

rm -rf decoded
java -jar "$APKTOOL" d -f -o decoded "$SRC"
python3 patch.py decoded
OUT=JuneCloudMessaging_nopin_signed.apk
if [ "$TOKEN_FALLBACK" = "1" ]; then
  python3 patch.py decoded --token-fallback
  OUT=JuneCloudMessaging_nopin_fallback_signed.apk
  echo "[!] token-fallback JCM patch is bench-only and NOT shipped until P4 passes (docs/jcm-token-fallback.md)" >&2
fi
java -jar "$APKTOOL" b decoded -o jcm_nopin_unsigned.apk
jarsigner -keystore "$KS" -storetype PKCS12 -storepass june \
  -sigalg SHA256withRSA -digestalg SHA-256 jcm_nopin_unsigned.apk june
cp jcm_nopin_unsigned.apk "$OUT"
sha256sum "$OUT"
echo "OK -> $OUT"
