#!/usr/bin/env bash
# Publish a June USB release to downloads.project-july.org (R2 bucket
# "project-july-downloads", rclone remote "r2"; override with JUNE_R2_REMOTE).
#
#   june-usb/VERSION/June-USB.exe, June-USB.dmg, SHA256SUMS   kept per version
#   june-usb/June-USB.exe, June-USB.dmg, SHA256SUMS           what the website links
#
# Usage: publish_usbtool.sh VERSION DIR [--dry-run]
#   DIR holds June-USB.exe, June-USB.dmg and SHA256SUMS, e.g. the files from
#   the draft GitHub release that .github/workflows/june-usb.yml made.
set -euo pipefail

[ $# -ge 2 ] || { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
version="$1"
dir="$2"
dry=0
[ "${3:-}" = "--dry-run" ] && dry=1
remote="${JUNE_R2_REMOTE:-r2:project-july-downloads}"
public="https://downloads.project-july.org/june-usb"

[[ "$version" =~ ^usb-v[0-9]+(\.[0-9]+)*$ ]] || { echo "VERSION must look like usb-v1.0 (the release tag)" >&2; exit 2; }
for f in June-USB.exe June-USB.dmg SHA256SUMS; do
  [ -f "$dir/$f" ] || { echo "$dir/$f is missing" >&2; exit 2; }
done
(cd "$dir" && sha256sum -c SHA256SUMS) || { echo "SHA256SUMS does not match the files" >&2; exit 1; }

run() {
  echo "+ $*"
  [ "$dry" = 1 ] || "$@"
}

if [ -n "$(rclone lsf "$remote/june-usb/$version/" 2>/dev/null)" ]; then
  echo "june-usb/$version already exists on R2; published versions are never overwritten." >&2
  exit 1
fi
for f in June-USB.exe June-USB.dmg SHA256SUMS; do
  run rclone copyto "$dir/$f" "$remote/june-usb/$version/$f"
done
# The unversioned copies are what the website links; keep their cache short.
for f in June-USB.exe June-USB.dmg SHA256SUMS; do
  run rclone copyto "$dir/$f" "$remote/june-usb/$f" --header-upload "Cache-Control: public, max-age=300"
done

if [ "$dry" = 0 ]; then
  for f in June-USB.exe June-USB.dmg; do
    want="$(stat -c %s "$dir/$f")"
    got="$(curl -fsSI "$public/$f?v=$version" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2}')"
    [ "$got" = "$want" ] && echo "OK: $public/$f ($want bytes)" || echo "Check $public/$f: got ${got:-nothing}, expected $want bytes" >&2
  done
fi
