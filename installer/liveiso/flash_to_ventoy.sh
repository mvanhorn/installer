#!/usr/bin/env bash
# Copy the freshly built live ISO onto a mounted Ventoy data partition and
# verify the copy by comparing SHA256 sums.
#
# Why this exists: /mnt/ventoy is easy to create as a plain directory, and a
# copy there silently writes to the local disk instead of the USB stick.  This
# script only writes to a real mountpoint, so a failed flash is impossible to
# mistake for a successful one.
set -euo pipefail

cd "$(dirname "$0")"

ISO="${1:-$(pwd)/june-local-live.iso}"
if [ ! -f "$ISO" ]; then
  echo "error: ISO not found: $ISO" >&2
  exit 1
fi

find_ventoy_mount() {
  local dev mnt line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    dev="$(printf '%s\n' "$line" | awk '{print $1}')"
    mnt="$(printf '%s\n' "$line" | awk '{print $2}')"
    case "$dev" in
      /dev/*) ;;
      *) continue ;;
    esac
    if mountpoint -q "$mnt" 2>/dev/null; then
      printf '%s\n' "$mnt"
      return 0
    fi
  done < <(findmnt -rno SOURCE,TARGET --submounts 2>/dev/null | grep -i ventoy || true)

  # Fallback: look up the device by lsblk label.
  while IFS= read -r dev; do
    [ -n "$dev" ] || continue
    while IFS= read -r mnt; do
      [ -n "$mnt" ] || continue
      if mountpoint -q "$mnt" 2>/dev/null; then
        printf '%s\n' "$mnt"
        return 0
      fi
    done < <(findmnt -rno TARGET --source "$dev" 2>/dev/null || true)
  done < <(lsblk -rno PATH,LABEL 2>/dev/null | awk '$2=="Ventoy"{print $1}')
  return 1
}

MOUNT="$(find_ventoy_mount || true)"
if [ -z "$MOUNT" ]; then
  echo "error: no mounted Ventoy data partition found." >&2
  echo "Mount the Ventoy stick first, for example:" >&2
  echo "  udisksctl mount -b /dev/sdX1" >&2
  echo "or mount it as root and re-run this script." >&2
  exit 1
fi

if ! mountpoint -q "$MOUNT"; then
  echo "error: $MOUNT is not a mountpoint (is it a plain directory?)." >&2
  exit 1
fi

SRC_HASH="$(sha256sum "$ISO" | awk '{print $1}')"
SRC_SIZE="$(stat -c '%s' "$ISO")"
DEST="$MOUNT/$(basename "$ISO")"

AVAIL="$(df -B1 --output=avail "$MOUNT" | tail -n1 | tr -d ' ')"
if [ "${AVAIL:-0}" -lt "$SRC_SIZE" ]; then
  echo "error: not enough free space on $MOUNT for $(basename "$ISO")" >&2
  exit 1
fi

echo "Copying $(basename "$ISO")"
echo "  from: $ISO"
echo "  to:   $DEST"
echo "  sha256: $SRC_HASH"

cp "$ISO" "$DEST"
sync

if ! DEST_HASH="$(sha256sum "$DEST" | awk '{print $1}')"; then
  echo "error: could not hash the copied file on the stick." >&2
  exit 1
fi
if [ "$DEST_HASH" != "$SRC_HASH" ]; then
  echo "error: hash mismatch after copy - the stick is NOT updated." >&2
  echo "  expected $SRC_HASH" >&2
  echo "  got      $DEST_HASH" >&2
  exit 1
fi

echo
echo "Ventoy stick updated and verified:"
echo "  $DEST"
echo "  sha256 $DEST_HASH"
echo
echo "You can now eject the stick and boot it."
