#!/usr/bin/env bash
# Build JuneDns_signed.apk (package com.july.dns) from this apktool tree.
#
# Same pattern as ../oven-light/build.sh: apktool rebuild + jarsigner with the
# project APK key. The oven's Android 5.0.1 only needs a v1 JAR signature.
#
# Overrides:
#   APKTOOL   apktool binary        (default: apktool)
#   KS        keystore              (default: june_apk_sign.p12 in this dir)
#   KS_PASS   keystore password     (default: june)
#   KS_ALIAS  signing alias         (default: june)
#
# Output: JuneDns_signed.apk (copy it into the installer payload; the
# identity-installer side adds it to prepare_assets.sh/deploy_onoven.sh).
set -euo pipefail
cd "$(dirname "$0")"

APKTOOL="${APKTOOL:-apktool}"
KS="${KS:-june_apk_sign.p12}"
KS_PASS="${KS_PASS:-june}"
KS_ALIAS="${KS_ALIAS:-june}"

for tool in "$APKTOOL" jarsigner java sha256sum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "[-] missing build tool: $tool" >&2
    exit 1
  fi
done
if [ ! -f "$KS" ]; then
  echo "[-] keystore not found: $KS" >&2
  echo "    set KS=/path/to/June/tools/certs/june_apk_sign.p12 and retry" >&2
  exit 1
fi

"$APKTOOL" b . -o JuneDns_unsigned.apk

jarsigner -keystore "$KS" -storetype PKCS12 -storepass "$KS_PASS" \
  -sigalg SHA256withRSA -digestalg SHA-256 JuneDns_unsigned.apk "$KS_ALIAS"

cp -f JuneDns_unsigned.apk JuneDns_signed.apk
sha256sum JuneDns_signed.apk
echo "OK -> JuneDns_signed.apk"
