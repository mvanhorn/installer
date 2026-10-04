#!/usr/bin/env bash
# Deploy the on-oven June local server (Go) over UMS.
#
# Run as root with the oven already in UMS mode (/dev/sda = the 7.3G eMMC block
# device). This script is deliberately paranoid: it refuses to run if /dev/sda
# is a regular file (the phantom-file trap that ate a dd earlier).
#
# What it installs:
#   /system/xbin/june-local          static ARMv7 Go server
#   /system/etc/june_leaf.crt        TLS chain (real GoDaddy *.junelife.com leaf)
#   /system/etc/june_leaf.key        TLS leaf private key (0600)
#   /system/etc/hosts                api/messaging -> 127.0.0.1
#   /data/june/media                 live-view JPEG directory
#   /data/june/logs                  server log + JSONL directory
#   /system/bin/june_bootclear.sh    force-adb only (no server launch)
#   /system/etc/june/jcm_nopin.apk or /data/june/jcm_nopin.apk
#       staged patched JCM for the post-boot jcm_apply service
#   LNX/boot partition               boot_junelocal_init.img (dedicated init service)
#
# Optional env overrides:
#   CERT_SRC / KEY_SRC / BIN_SRC / JCM_SRC / BOOT_SRC
#   FLASH_BOOT=0   skip flashing the boot partition (LNX)
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SRC_DIR/../../.." && pwd)"

EXPECTED_SIZE="7818182656"

# Given a mounted source such as /dev/sda1, return the whole disk (/dev/sda).
disk_from_source() {
  local src="$1" base parent
  case "$src" in
    /dev/*) ;;
    *) return 1 ;;
  esac
  base="${src##*/}"

  # A partition source: walk its sysfs symlink back to the parent block device.
  if [ -e "/sys/class/block/$base/partition" ]; then
    parent="$(basename "$(dirname "$(readlink -f "/sys/class/block/$base")")")"
    [ -n "$parent" ] || return 1
    printf '/dev/%s\n' "$parent"
    return 0
  fi

  # Already a whole-disk device.
  if [ -b "$src" ] && [ -d "/sys/class/block/$base" ]; then
    printf '%s\n' "$src"
    return 0
  fi

  return 1
}

# The disk we booted from (or the disk holding the live medium) must never be
# treated as the oven.  This is the /sda phantom trap: on a live USB stick the
# boot media is often /dev/sda, while the oven appears as a later disk.
boot_or_root_disk() {
  local target src dev
  for target in /run/live/medium /lib/live/mount/medium /; do
    src="$(findmnt -n -o SOURCE --target "$target" 2>/dev/null || true)"
    case "$src" in
      ""|overlay|tmpfs) continue ;;
    esac
    dev="$(disk_from_source "$src" 2>/dev/null || true)"
    if [ -n "$dev" ]; then
      printf '%s\n' "$dev"
      return 0
    fi
  done
  return 1
}

find_june_disk() {
  local excluded b dev sz
  excluded="$(boot_or_root_disk || true)"
  for b in /sys/block/*; do
    [ -e "$b/device" ] || continue
    dev="/dev/$(basename "$b")"
    [ -b "$dev" ] || continue
    if [ -n "$excluded" ] && [ "$dev" = "$excluded" ]; then
      continue
    fi
    sz="$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)"
    if [ "$sz" = "$EXPECTED_SIZE" ]; then
      printf '%s\n' "$dev"
      return 0
    fi
  done
  return 1
}

BOOT_OR_ROOT_DISK="$(boot_or_root_disk || true)"
DEV="${DEV:-$(find_june_disk || true)}"

BIN_SRC="${BIN_SRC:-$ROOT/local-resources/june-arch/golocal/bin/june-local-linux-armv7}"
CAMERAD_SRC="${CAMERAD_SRC:-$ROOT/local-resources/june-arch/golocal/bin/june-camerad-linux-armv7}"
CERT_SRC="${CERT_SRC:-$ROOT/tools/certs/junelife_chain_godaddy_intermediate.crt}"
KEY_SRC="${KEY_SRC:-$ROOT/tools/certs/june-local.key}"
CA_SRC="${CA_SRC:-}"
CA_HASH="${CA_HASH:-}"
JCM_SRC="${JCM_SRC:-$ROOT/local-resources/june-rcm/healthy-build/decrypted-priv-app/JuneCloudMessaging.apk}"
REMOTES_SRC="${REMOTES_SRC:-}"
BOOTCLEAR_SRC="${BOOTCLEAR_SRC:-$SRC_DIR/june_bootclear.sh.onoven}"
JUNE_REAPER_SRC="${JUNE_REAPER_SRC:-$SRC_DIR/june_reaper.sh.junelocal}"
COMPANION_STATE_SRC="${COMPANION_STATE_SRC:-$ROOT/local-resources/june-arch/companions_state.json}"
BOOT_SRC="${BOOT_SRC:-$ROOT/local-resources/june-arch/tools/orchestrator/boot_junelocal_init.img}"
FLASH_BOOT="${FLASH_BOOT:-1}"
JCM_PERSIST="${JCM_PERSIST:-0}"

APP_OFF=$((92928 * 512))
UDA_OFF=$((8039680 * 512))
SLN_OFF=$((2755328 * 512))
SAP_OFF=$((2771712 * 512))
LNX_OFF=$((76544 * 512))
LNX_SIZE=$((16384 * 512))
SLN_SIZE=$((16384 * 512))

APP_MNT="/mnt/june_app"
UDA_MNT="/mnt/june_uda"
SAP_MNT="/mnt/june_sap"

require_block_device() {
  if [ -z "$DEV" ] || [ ! -b "$DEV" ]; then
    echo "[-] June eMMC block device not found. Put the oven in UMS mode first." >&2
    if [ -n "$BOOT_OR_ROOT_DISK" ]; then
      echo "[-] Excluded boot/system disk: $BOOT_OR_ROOT_DISK" >&2
    fi
    exit 1
  fi
  local sz
  sz="$(blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)"
  if [ "$sz" != "$EXPECTED_SIZE" ]; then
    echo "[-] $DEV size is $sz, expected $EXPECTED_SIZE (June eMMC)." >&2
    echo "[-] Refusing to flash: this looks like the wrong disk." >&2
    exit 1
  fi
}

cleanup() {
  umount "$APP_MNT" "$UDA_MNT" "$SAP_MNT" 2>/dev/null || true
  losetup -d "${LOOP_APP:-}" "${LOOP_UDA:-}" "${LOOP_SAP:-}" 2>/dev/null || true
}
trap cleanup EXIT

require_block_device
echo "[*] target disk: $DEV"
echo "[*] excluded boot/system disk: ${BOOT_OR_ROOT_DISK:-none}"

install_system_files() {
  local mnt="$1"
  install -m 0755 "$BIN_SRC" "$mnt/xbin/june-local"
  install -m 0755 "$CAMERAD_SRC" "$mnt/xbin/june-camerad"
  install -m 0644 "$CERT_SRC" "$mnt/etc/june_leaf.crt"
  install -m 0600 "$KEY_SRC" "$mnt/etc/june_leaf.key"
  if [ -n "$CA_SRC" ] && [ -n "$CA_HASH" ]; then
    mkdir -p "$mnt/etc/security/cacerts"
    install -m 0644 "$CA_SRC" "$mnt/etc/security/cacerts/$CA_HASH.0"
  fi
  install -m 0755 "$BOOTCLEAR_SRC" "$mnt/bin/june_bootclear.sh"
  # june_reaper.sh is the stock boot script that mounts the encrypted
  # /system/collector volume. The June Local copy mounts that same volume
  # read-write when a staged JCM patch exists and applies it before Android
  # starts; without a staged patch it behaves exactly like the stock script.
  install -m 0755 "$JUNE_REAPER_SRC" "$mnt/bin/june_reaper.sh"

  # Advertise the configured hostname over mDNS. june_reaper sets net.hostname
  # from this file at boot and Android's NsdService then publishes
  # <name>.local (the certificate already carries the matching SAN).
  hostname_value="${OVEN_HOST:-june-oven}"
  hostname_value="${hostname_value%.local}"
  [ -n "$hostname_value" ] || hostname_value="june-oven"
  printf '%s\n' "$hostname_value" > "$mnt/etc/june_hostname"
  chmod 0644 "$mnt/etc/june_hostname"
  echo "[*] oven hostname: $hostname_value (will advertise $hostname_value.local)"

  # The live Android build deletes raw /system/priv-app at boot and mounts the
  # encrypted /system/collector EncFS volume over it, so writing the APK there
  # never affects the running package. The patched june_reaper.sh performs the
  # encrypted write during the first mount of that volume, before Android
  # starts; the boot image's one-shot `jcm_apply` service remains as a
  # fallback. When persistence is requested, the patched APK is staged in
  # /system so it is still available after a factory reset.
  case "$(basename "$JCM_SRC")" in
    JuneCloudMessaging_nopin_signed.apk)
      if [ "$JCM_PERSIST" = "1" ]; then
        mkdir -p "$mnt/etc/june"
        install -m 0644 "$JCM_SRC" "$mnt/etc/june/jcm_nopin.apk"
        jcm_dst_sha="$(sha256sum "$mnt/etc/june/jcm_nopin.apk" | awk '{print $1}')"
        jcm_src_sha="$(sha256sum "$JCM_SRC" | awk '{print $1}')"
        if [ "$jcm_dst_sha" != "$jcm_src_sha" ]; then
          echo "[-] persistent JCM APK write mismatch on $mnt" >&2
          echo "    src: $jcm_src_sha ($(stat -c '%s' "$JCM_SRC") bytes)" >&2
          echo "    dst: $jcm_dst_sha ($(stat -c '%s' "$mnt/etc/june/jcm_nopin.apk") bytes)" >&2
          exit 1
        fi
        echo "[+] persistent JCM patch staged on $mnt/etc/june/jcm_nopin.apk ($(stat -c '%s' "$JCM_SRC") bytes)"
      else
        rm -f "$mnt/etc/june/jcm_nopin.apk"
        if [ "${JCM_NOTICE_SHOWN:-0}" != "1" ]; then
          echo "[ ] JCM patch will be staged in /data (not persistent across factory reset)"
          JCM_NOTICE_SHOWN=1
        fi
      fi
      ;;
    *)
      # The prepackaged install uses the factory JCM. Never leave a factory
      # APK at the custom-patch staging path: jcm_apply would prefer it over
      # the real no-pin APK staged in /data.
      rm -f "$mnt/etc/june/jcm_nopin.apk"
      ;;
  esac

  # Remotes (the oven-side pairing UI) embeds the same pinned network client,
  # so a per-home CA only works once it is patched as well.
  if [ -n "$REMOTES_SRC" ]; then
    if [ "$JCM_PERSIST" = "1" ]; then
      mkdir -p "$mnt/etc/june"
      install -m 0644 "$REMOTES_SRC" "$mnt/etc/june/remotes_nopin.apk"
      rem_dst_sha="$(sha256sum "$mnt/etc/june/remotes_nopin.apk" | awk '{print $1}')"
      rem_src_sha="$(sha256sum "$REMOTES_SRC" | awk '{print $1}')"
      if [ "$rem_dst_sha" != "$rem_src_sha" ]; then
        echo "[-] persistent Remotes APK write mismatch on $mnt" >&2
        echo "    src: $rem_src_sha ($(stat -c '%s' "$REMOTES_SRC") bytes)" >&2
        echo "    dst: $rem_dst_sha ($(stat -c '%s' "$mnt/etc/june/remotes_nopin.apk") bytes)" >&2
        exit 1
      fi
      echo "[+] persistent Remotes patch staged on $mnt/etc/june/remotes_nopin.apk ($(stat -c '%s' "$REMOTES_SRC") bytes)"
    else
      rm -f "$mnt/etc/june/remotes_nopin.apk"
      echo "[ ] Remotes patch will be staged in /data (not persistent across factory reset)"
    fi
  else
    rm -f "$mnt/etc/june/remotes_nopin.apk"
  fi

  if ! grep -qE '^127\.0\.0\.1[[:space:]]+api\.junelife\.com([[:space:]]|$)' "$mnt/etc/hosts"; then
    printf '\n127.0.0.1 api.junelife.com\n' >> "$mnt/etc/hosts"
  fi
  if ! grep -qE '^127\.0\.0\.1[[:space:]]+messaging\.junelife\.com([[:space:]]|$)' "$mnt/etc/hosts"; then
    printf '127.0.0.1 messaging.junelife.com\n' >> "$mnt/etc/hosts"
  fi

}

required_sources=("$BIN_SRC" "$CAMERAD_SRC" "$CERT_SRC" "$KEY_SRC" "$JCM_SRC" "$BOOTCLEAR_SRC" "$JUNE_REAPER_SRC" "$COMPANION_STATE_SRC")
if [ -n "$REMOTES_SRC" ]; then
  required_sources+=("$REMOTES_SRC")
fi
if [ -n "$CA_SRC" ]; then
  required_sources+=("$CA_SRC")
fi
if [ "$FLASH_BOOT" = "1" ]; then
  required_sources+=("$BOOT_SRC")
fi
for f in "${required_sources[@]}"; do
  [ -f "$f" ] || { echo "[-] missing source file: $f" >&2; exit 1; }
done

echo "[*] binary: $BIN_SRC"
echo "[*] camerad: $CAMERAD_SRC"
echo "[*] cert:   $CERT_SRC"
echo "[*] key:    $KEY_SRC"
echo "[*] jcm:    $JCM_SRC"
echo "[*] jcm persistence: $JCM_PERSIST (1 = /system, 0 = /data)"
echo "[*] companions: $COMPANION_STATE_SRC"
echo "[*] boot:   $BOOT_SRC (flash=$FLASH_BOOT)"

# --- LNX/boot partition ---
if [ "$FLASH_BOOT" = "1" ]; then
  boot_size="$(stat -c '%s' "$BOOT_SRC")"
  if [ "$boot_size" -gt "$LNX_SIZE" ]; then
    echo "[-] boot image ($boot_size) exceeds LNX partition ($LNX_SIZE)" >&2
    exit 1
  fi
  echo "[*] flashing boot image to LNX (seek=76544)"
  dd if="$BOOT_SRC" of="$DEV" bs=512 seek=76544 conv=fsync status=none
  echo "[*] flashing boot image to SLN (seek=2755328)"
  dd if="$BOOT_SRC" of="$DEV" bs=512 seek=2755328 conv=fsync status=none
  sync
  echo "[+] boot image flashed to LNX + SLN ($boot_size bytes)"
fi

# --- APP/system ---
LOOP_APP="$(losetup -f --show -o "$APP_OFF" "$DEV")"
mkdir -p "$APP_MNT"
mount -t ext4 -o rw "$LOOP_APP" "$APP_MNT"
install_system_files "$APP_MNT"

sync
umount "$APP_MNT"
losetup -d "$LOOP_APP"
LOOP_APP=""

# --- SAP/factory fallback system ---
LOOP_SAP="$(losetup -f --show -o "$SAP_OFF" "$DEV")"
mkdir -p "$SAP_MNT"
if ! mount -t ext4 -o rw "$LOOP_SAP" "$SAP_MNT"; then
  echo "[!] SAP rw mount failed; running e2fsck -f then retrying"
  e2fsck -f -y "$LOOP_SAP" || true
  mount -t ext4 -o rw "$LOOP_SAP" "$SAP_MNT"
fi
install_system_files "$SAP_MNT"

sync
umount "$SAP_MNT"
losetup -d "$LOOP_SAP"
LOOP_SAP=""

# --- UDA/data ---
LOOP_UDA="$(losetup -f --show -o "$UDA_OFF" "$DEV")"
mkdir -p "$UDA_MNT"
if ! mount -t ext4 -o rw "$LOOP_UDA" "$UDA_MNT"; then
  echo "[!] /data rw mount failed; running e2fsck -f then retrying"
  e2fsck -f -y "$LOOP_UDA" || true
  mount -t ext4 -o rw "$LOOP_UDA" "$UDA_MNT"
fi

mkdir -p "$UDA_MNT/june/media" "$UDA_MNT/june/logs"
chmod 0755 "$UDA_MNT/june" "$UDA_MNT/june/media" "$UDA_MNT/june/logs"
install -m 0644 "$COMPANION_STATE_SRC" "$UDA_MNT/june/companions_state.json"
case "$(basename "$JCM_SRC")" in
  JuneCloudMessaging_nopin_signed.apk)
    if [ "$JCM_PERSIST" = "1" ]; then
      echo "[ ] persistent JCM patch staged in /system/etc/june/jcm_nopin.apk"
    else
      install -m 0644 "$JCM_SRC" "$UDA_MNT/june/jcm_nopin.apk"
      jcm_dst_sha="$(sha256sum "$UDA_MNT/june/jcm_nopin.apk" | awk '{print $1}')"
      jcm_src_sha="$(sha256sum "$JCM_SRC" | awk '{print $1}')"
      if [ "$jcm_dst_sha" != "$jcm_src_sha" ]; then
        echo "[-] /data JCM APK write mismatch" >&2
        echo "    src: $jcm_src_sha" >&2
        echo "    dst: $jcm_dst_sha" >&2
        exit 1
      fi
      echo "[+] non-persistent JCM patch staged in /data/june/jcm_nopin.apk ($(stat -c '%s' "$JCM_SRC") bytes)"
    fi
    ;;
  *)
    # Standard install: the factory JuneCloudMessaging app is used as-is.
    # Remove any payload left behind by an earlier patched install so the
    # post-boot applier cannot resurrect a stale patch (and never write the
    # factory APK under the patch name).
    rm -f "$UDA_MNT/june/jcm_nopin.apk"
    echo "[*] standard install keeps the factory JuneCloudMessaging app (no JCM patch staged)"
    ;;
esac

if [ -n "$REMOTES_SRC" ]; then
  if [ "$JCM_PERSIST" != "1" ]; then
    install -m 0644 "$REMOTES_SRC" "$UDA_MNT/june/remotes_nopin.apk"
    rem_dst_sha="$(sha256sum "$UDA_MNT/june/remotes_nopin.apk" | awk '{print $1}')"
    rem_src_sha="$(sha256sum "$REMOTES_SRC" | awk '{print $1}')"
    if [ "$rem_dst_sha" != "$rem_src_sha" ]; then
      echo "[-] /data Remotes APK write mismatch" >&2
      echo "    src: $rem_src_sha" >&2
      echo "    dst: $rem_dst_sha" >&2
      exit 1
    fi
    echo "[+] non-persistent Remotes patch staged in /data/june/remotes_nopin.apk ($(stat -c '%s' "$REMOTES_SRC") bytes)"
  else
    echo "[ ] persistent Remotes patch staged in /system/etc/june/remotes_nopin.apk"
  fi
else
  rm -f "$UDA_MNT/june/remotes_nopin.apk"
fi

# Presets/recipes content mirror: june-local serves the catalog and program
# bundles from /capture/upstream-content (june_reaper links /capture to /data),
# which is what guided programs such as Proof and Slow Cook load.
if [ -d "$SRC_DIR/upstream-content" ]; then
  content_kb="$(du -sk "$SRC_DIR/upstream-content" | awk '{print $1}')"
  avail_kb="$(df -Pk "$UDA_MNT" 2>/dev/null | awk 'NR==2{print $4}')"
  if [ "${avail_kb:-0}" -gt $(( content_kb + 65536 )) ]; then
    echo "[*] installing preset/recipe content ($(( content_kb / 1024 )) MB) to /data/june/upstream-content..."
    rm -rf "$UDA_MNT/june/upstream-content"
    cp -a "$SRC_DIR/upstream-content" "$UDA_MNT/june/upstream-content"
    echo "[+] preset content installed ($(du -sh "$UDA_MNT/june/upstream-content" 2>/dev/null | cut -f1)); guided programs enabled"
  else
    echo "[!] not enough space on /data for preset content (need $(( content_kb / 1024 )) MB, have $(( ${avail_kb:-0} / 1024 )) MB); guided programs will be unavailable" >&2
  fi
else
  echo "[i] no preset content in the payload; guided programs (proof, slow cook, recipes) will be unavailable"
fi

sync
umount "$UDA_MNT"
losetup -d "$LOOP_UDA"
LOOP_UDA=""

echo "[+] deployed. SHA256 of staged files:"
if [ "$FLASH_BOOT" = "1" ]; then
  sha256sum "$BIN_SRC" "$CAMERAD_SRC" "$CERT_SRC" "$KEY_SRC" "$JCM_SRC" "$BOOTCLEAR_SRC" "$JUNE_REAPER_SRC" "$COMPANION_STATE_SRC" "$BOOT_SRC"
else
  sha256sum "$BIN_SRC" "$CAMERAD_SRC" "$CERT_SRC" "$KEY_SRC" "$JCM_SRC" "$BOOTCLEAR_SRC" "$JUNE_REAPER_SRC" "$COMPANION_STATE_SRC"
fi
echo "[+] power-cycle the oven normally; the junelocal init service starts june-local at boot_completed."
