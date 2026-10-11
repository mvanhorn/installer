#!/usr/bin/env bash
# Build Chef_cookmodes_signed.apk from the stock Chef APK.
#
# Usage:
#   ./build_patched.sh [stock-Chef.apk] [output.apk]
#
# Defaults:
#   stock  ../.. .../june-rcm/healthy-build/decompiled/priv-app-apks/Chef.apk
#   output ./Chef_cookmodes_signed.apk
#
# The decoded tree and intermediate APK live in a temp dir and are removed on
# exit. Requires apktool, python3, java/jarsigner and the project APK key.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JUNE_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

STOCK="${1:-$JUNE_ROOT/local-resources/june-rcm/healthy-build/decompiled/priv-app-apks/Chef.apk}"
OUT="${2:-$SCRIPT_DIR/Chef_cookmodes_signed.apk}"

APKTOOL="${APKTOOL:-apktool}"
KS="${KS:-$JUNE_ROOT/tools/certs/june_apk_sign.p12}"
KS_PASS="${KS_PASS:-june}"
KS_ALIAS="${KS_ALIAS:-june}"

[ -f "$STOCK" ] || { echo "stock APK not found: $STOCK" >&2; exit 1; }
[ -x "$APKTOOL" ] || { echo "apktool not found: $APKTOOL" >&2; exit 1; }
[ -f "$KS" ] || { echo "signing keystore not found: $KS" >&2; exit 1; }

WORK="$(mktemp -d /tmp/chef-cookmodes.XXXXXX)"
cleanup() {
  case "$WORK" in
    /tmp/chef-cookmodes.*) rm -rf -- "$WORK" ;;
  esac
}
trap cleanup EXIT

echo "[*] stock:  $STOCK"
echo "[*] work:   $WORK"
echo "[*] decode (resources kept raw)"
"$APKTOOL" d -r -f -o "$WORK/decoded" "$STOCK" > "$WORK/decode.log" 2>&1

echo "[*] patch smali"
python3 "$SCRIPT_DIR/patch.py" "$WORK/decoded"

echo "[*] rebuild"
"$APKTOOL" b "$WORK/decoded" -o "$WORK/Chef_cookmodes_unsigned.apk" > "$WORK/build.log" 2>&1

echo "[*] sign with $KS_ALIAS"
cp "$WORK/Chef_cookmodes_unsigned.apk" "$OUT"
jarsigner -keystore "$KS" -storetype PKCS12 -storepass "$KS_PASS" \
  -sigalg SHA256withRSA -digestalg SHA-256 "$OUT" "$KS_ALIAS"

keytool -printcert -jarfile "$OUT" 2>/dev/null | grep -m1 Owner || true
sha256sum "$OUT"
echo "[+] wrote $OUT"
