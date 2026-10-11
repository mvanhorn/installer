#!/usr/bin/env bash
# Publish a built ISO to downloads.project-july.org and point the June USB
# app at it.
#
# downloads.project-july.org is the public custom domain of the R2 bucket
# "project-july-downloads"; this script writes to it with rclone (remote
# "r2", override with JUNE_R2_REMOTE):
#
#   installer/VERSION/june-local-live.iso         the ISO (never overwritten)
#   installer/VERSION/june-local-live.iso.sha256  its checksum
#   installer/latest.json                          what June USB downloads
#
# Usage:
#   publish_release.sh VERSION ISO                  upload ISO, then latest.json
#   publish_release.sh VERSION ISO --manifest-only  ISO already uploaded: only
#                                                   write latest.json for it
#   add --dry-run to print what would happen without uploading.
#
# The https://downloads.project-july.org/installer/latest redirect is a
# Cloudflare redirect rule and still has to be pointed at VERSION by hand
# (see PUBLISHING.md).
set -euo pipefail

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 2 ] || usage
version="$1"
iso="$2"
shift 2
manifest_only=0
dry=0
for arg in "$@"; do
  case "$arg" in
    --manifest-only) manifest_only=1 ;;
    --dry-run) dry=1 ;;
    *) usage ;;
  esac
done

remote="${JUNE_R2_REMOTE:-r2:project-july-downloads}"
public="https://downloads.project-july.org/installer"
name="june-local-live.iso"

[[ "$version" =~ ^v[0-9]+(\.[0-9]+)*$ ]] || { echo "VERSION must look like v0.6" >&2; exit 2; }
[ -f "$iso" ] || { echo "$iso does not exist" >&2; exit 2; }
command -v rclone >/dev/null || { echo "rclone is required (remote: $remote)" >&2; exit 2; }

run() {
  echo "+ $*"
  [ "$dry" = 1 ] || "$@"
}

echo "Hashing $iso ..."
sha="$(sha256sum "$iso" | cut -d' ' -f1)"
size="$(stat -c %s "$iso")"
echo "  $version  $size bytes  sha256 $sha"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

remote_size() {
  rclone lsjson "$remote/installer/$version/$name" 2>/dev/null | grep -o '"Size":[0-9]*' | cut -d: -f2 || true
}

if [ "$manifest_only" = 1 ]; then
  have="$(remote_size)"
  if [ "$have" != "$size" ]; then
    echo "installer/$version/$name on R2 is ${have:-missing}, not $size bytes; refusing to publish a manifest for it." >&2
    exit 1
  fi
else
  if [ -n "$(remote_size)" ]; then
    echo "installer/$version/$name already exists on R2. Published versions are never overwritten;" >&2
    echo "use a new version, or --manifest-only if this is the same file." >&2
    exit 1
  fi
  run rclone copyto "$iso" "$remote/installer/$version/$name" \
    --s3-chunk-size 64M --progress --header-upload "Content-Type: application/x-iso9660-image"
  printf '%s  %s\n' "$sha" "$name" > "$work/$name.sha256"
  run rclone copyto "$work/$name.sha256" "$remote/installer/$version/$name.sha256" \
    --header-upload "Content-Type: text/plain"
fi

# Check the public URL serves exactly this file before pointing the app at it.
if [ "$dry" = 0 ]; then
  got="$(curl -fsSI "$public/$version/$name" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2}')"
  if [ "$got" != "$size" ]; then
    echo "$public/$version/$name answers with ${got:-no} Content-Length, expected $size; not updating latest.json." >&2
    exit 1
  fi
fi

printf '{"version": "%s", "url": "%s/%s/%s", "sha256": "%s", "size": %s}\n' \
  "$version" "$public" "$version" "$name" "$sha" "$size" > "$work/latest.json"
echo "latest.json:"
cat "$work/latest.json"
run rclone copyto "$work/latest.json" "$remote/installer/latest.json" \
  --header-upload "Content-Type: application/json" --header-upload "Cache-Control: public, max-age=300"

if [ "$dry" = 0 ]; then
  if curl -fsS "$public/latest.json?v=$sha" | grep -q "\"sha256\": \"$sha\""; then
    echo "OK: $public/latest.json now points at $version."
  else
    echo "Uploaded, but $public/latest.json does not show the new hash yet (cache?). Check it by hand." >&2
  fi
fi
echo
echo "Remaining by hand: point the $public/latest redirect rule at $version, and update the"
echo "SHA256 on the website and in CREATE_VENTOY_USB.md."
