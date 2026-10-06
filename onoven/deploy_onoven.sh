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
MEDIACAPTURER_SRC="${MEDIACAPTURER_SRC:-}"
ANALYTICS_SRC="${ANALYTICS_SRC:-}"
CHEF_SRC="${CHEF_SRC:-}"
LIGHT_SRC="${LIGHT_SRC:-$SRC_DIR/OvenLight_signed.apk}"
BOOTCLEAR_SRC="${BOOTCLEAR_SRC:-$SRC_DIR/june_bootclear.sh.onoven}"
JUNE_REAPER_SRC="${JUNE_REAPER_SRC:-$SRC_DIR/june_reaper.sh.junelocal}"
COMPANION_STATE_SRC="${COMPANION_STATE_SRC:-$ROOT/local-resources/june-arch/companions_state.json}"
BOOT_SRC="${BOOT_SRC:-$ROOT/local-resources/june-arch/tools/orchestrator/boot_junelocal_init.img}"
FLASH_BOOT="${FLASH_BOOT:-1}"
JCM_PERSIST="${JCM_PERSIST:-0}"
CHEF_PERSISTED=0

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
  if [ -n "$CA_SRC" ]; then
    # Served at /local/ca.crt.  Custom installs hand out the per-home CA and
    # also add it to the system store; basic installs hand out the factory
    # chain and leave the store alone.
    install -m 0644 "$CA_SRC" "$mnt/etc/june_ca.crt"
  fi
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
  hostname_value="${OVEN_HOST:-june}"
  hostname_value="${hostname_value%.local}"
  [ -n "$hostname_value" ] || hostname_value="june"
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

  # MediaCapturer embeds the same pinned network client and uploads the
  # cook-time stills to June's cloud. With the pin neutralized and the
  # project CA trusted, those stills land on june-local instead, where
  # /1/videos/{id}/start_image rebroadcasts them as local 10011 frames.
  if [ -n "$MEDIACAPTURER_SRC" ]; then
    if [ "$JCM_PERSIST" = "1" ]; then
      mkdir -p "$mnt/etc/june"
      install -m 0644 "$MEDIACAPTURER_SRC" "$mnt/etc/june/mediacapturer_nopin.apk"
      mc_dst_sha="$(sha256sum "$mnt/etc/june/mediacapturer_nopin.apk" | awk '{print $1}')"
      mc_src_sha="$(sha256sum "$MEDIACAPTURER_SRC" | awk '{print $1}')"
      if [ "$mc_dst_sha" != "$mc_src_sha" ]; then
        echo "[-] persistent MediaCapturer APK write mismatch on $mnt" >&2
        echo "    src: $mc_src_sha ($(stat -c '%s' "$MEDIACAPTURER_SRC") bytes)" >&2
        echo "    dst: $mc_dst_sha ($(stat -c '%s' "$mnt/etc/june/mediacapturer_nopin.apk") bytes)" >&2
        exit 1
      fi
      echo "[+] persistent MediaCapturer patch staged on $mnt/etc/june/mediacapturer_nopin.apk ($(stat -c '%s' "$MEDIACAPTURER_SRC") bytes)"
    else
      rm -f "$mnt/etc/june/mediacapturer_nopin.apk"
      echo "[ ] MediaCapturer patch will be staged in /data (not persistent across factory reset)"
    fi
  else
    rm -f "$mnt/etc/june/mediacapturer_nopin.apk"
  fi

  # Chef (cook modes): widens the remote primitive whitelist and carries an
  # optional plan_index for toast levels and other multi-plan primitives. Chef
  # is a priv-app, so the APK is staged here and swapped into the collector
  # volume by june_reaper at boot. It is ~240 MB, so persist it only when the
  # partition has room; otherwise the /data staging below covers one boot.
  if [ -n "$CHEF_SRC" ] && [ "$JCM_PERSIST" = "1" ]; then
    chef_size="$(stat -c '%s' "$CHEF_SRC" 2>/dev/null || echo 0)"
    chef_need_kb=$(( (chef_size + 1023) / 1024 + 8192 ))
    chef_avail_kb="$(df -Pk "$mnt" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [ "${chef_avail_kb:-0}" -ge "$chef_need_kb" ]; then
      mkdir -p "$mnt/etc/june"
      if install -m 0644 "$CHEF_SRC" "$mnt/etc/june/chef_cookmodes.apk"; then
        chef_dst_sha="$(sha256sum "$mnt/etc/june/chef_cookmodes.apk" | awk '{print $1}')"
        chef_src_sha="$(sha256sum "$CHEF_SRC" | awk '{print $1}')"
        if [ "$chef_dst_sha" = "$chef_src_sha" ]; then
          CHEF_PERSISTED=$((CHEF_PERSISTED + 1))
          echo "[+] persistent Chef patch staged on $mnt/etc/june/chef_cookmodes.apk ($chef_size bytes)"
        else
          echo "[!] persistent Chef patch write mismatch on $mnt; will stage in /data" >&2
          rm -f "$mnt/etc/june/chef_cookmodes.apk"
        fi
      else
        echo "[!] persistent Chef patch write failed on $mnt; will stage in /data" >&2
      fi
    else
      echo "[!] not enough space on $mnt for the Chef patch (need $(( chef_need_kb / 1024 )) MB, have $(( ${chef_avail_kb:-0} / 1024 )) MB); will stage in /data" >&2
    fi
  fi

  # Analytics is a plain /system/app package and pins the same June cert. It
  # is not used for cooking, so replacing it only stops the constant TLS
  # retry noise; it is safe to install directly.
  if [ -n "$ANALYTICS_SRC" ]; then
    if [ -f "$mnt/app/Analytics/Analytics.apk" ]; then
      install -m 0644 "$ANALYTICS_SRC" "$mnt/app/Analytics/Analytics.apk"
      an_dst_sha="$(sha256sum "$mnt/app/Analytics/Analytics.apk" | awk '{print $1}')"
      an_src_sha="$(sha256sum "$ANALYTICS_SRC" | awk '{print $1}')"
      if [ "$an_dst_sha" != "$an_src_sha" ]; then
        echo "[-] Analytics APK write mismatch on $mnt" >&2
        echo "    src: $an_src_sha" >&2
        echo "    dst: $an_dst_sha" >&2
        exit 1
      fi
      echo "[+] Analytics no-pin patch installed on $mnt/app/Analytics/Analytics.apk"
    else
      echo "[!] Analytics APK not found on $mnt; skipping Analytics patch" >&2
    fi
  fi

  # June Light Bridge: tiny exported service that june-local starts to drive
  # CookManager's AxonService lighting scenes while the camera is viewed.
  if [ -f "$LIGHT_SRC" ]; then
    mkdir -p "$mnt/app/JuneLight"
    install -m 0644 "$LIGHT_SRC" "$mnt/app/JuneLight/JuneLight.apk"
    light_dst_sha="$(sha256sum "$mnt/app/JuneLight/JuneLight.apk" | awk '{print $1}')"
    light_src_sha="$(sha256sum "$LIGHT_SRC" | awk '{print $1}')"
    if [ "$light_dst_sha" != "$light_src_sha" ]; then
      echo "[-] June Light Bridge APK write mismatch on $mnt" >&2
      echo "    src: $light_src_sha" >&2
      echo "    dst: $light_dst_sha" >&2
      exit 1
    fi
    echo "[+] June Light Bridge installed on $mnt/app/JuneLight/JuneLight.apk"
  else
    echo "[!] June Light Bridge APK not found at $LIGHT_SRC; interior light wake disabled" >&2
  fi

  if ! grep -qE '^127\.0\.0\.1[[:space:]]+api\.junelife\.com([[:space:]]|$)' "$mnt/etc/hosts"; then
    printf '\n127.0.0.1 api.junelife.com\n' >> "$mnt/etc/hosts"
  fi
  if ! grep -qE '^127\.0\.0\.1[[:space:]]+messaging\.junelife\.com([[:space:]]|$)' "$mnt/etc/hosts"; then
    printf '127.0.0.1 messaging.junelife.com\n' >> "$mnt/etc/hosts"
  fi

}

required_sources=("$BIN_SRC" "$CAMERAD_SRC" "$CERT_SRC" "$KEY_SRC" "$JCM_SRC" "$BOOTCLEAR_SRC" "$JUNE_REAPER_SRC" "$COMPANION_STATE_SRC")
required_sources+=("$LIGHT_SRC")
if [ -n "$REMOTES_SRC" ]; then
  required_sources+=("$REMOTES_SRC")
fi
if [ -n "$MEDIACAPTURER_SRC" ]; then
  required_sources+=("$MEDIACAPTURER_SRC")
fi
if [ -n "$ANALYTICS_SRC" ]; then
  required_sources+=("$ANALYTICS_SRC")
fi
if [ -n "$CHEF_SRC" ]; then
  required_sources+=("$CHEF_SRC")
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
if [ -n "$REMOTES_SRC" ]; then
  echo "[*] remotes: $REMOTES_SRC"
fi
if [ -n "$MEDIACAPTURER_SRC" ]; then
  echo "[*] mediacapturer: $MEDIACAPTURER_SRC"
fi
if [ -n "$ANALYTICS_SRC" ]; then
  echo "[*] analytics: $ANALYTICS_SRC"
fi
if [ -n "$CHEF_SRC" ]; then
  echo "[*] chef: $CHEF_SRC ($(stat -c '%s' "$CHEF_SRC") bytes)"
else
  echo "[i] Chef cook-modes patch not staged (optional)"
fi
echo "[*] light: $LIGHT_SRC"
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
# Preserve an existing companion registry: a normal reinstall must never force
# clients to re-pair. The payload file only seeds a fresh /data.
if [ -s "$UDA_MNT/june/companions_state.json" ]; then
  reg_backup="$UDA_MNT/june/companions_state.json.preinstall-$(date +%Y%m%d-%H%M%S)"
  cp -f "$UDA_MNT/june/companions_state.json" "$reg_backup" 2>/dev/null || true
  reg_size="$(stat -c '%s' "$UDA_MNT/june/companions_state.json" 2>/dev/null || echo 0)"
  echo "[+] preserving existing companion registry ($reg_size bytes; backup $(basename "$reg_backup"))"
else
  install -m 0644 "$COMPANION_STATE_SRC" "$UDA_MNT/june/companions_state.json"
  echo "[+] seeded companion registry from payload"
fi

# Provenance for the status page and support: what was installed, how, and
# the expected hashes of the components june-local reports on.
comp_sha() {
  [ -n "${1:-}" ] && [ -f "$1" ] && sha256sum "$1" | awk '{print $1}' || true
}
case "$(basename "$JCM_SRC")" in
  JuneCloudMessaging_nopin_signed.apk) jcm_sha="$(comp_sha "$JCM_SRC")" ;;
  *) jcm_sha="" ;;
esac
install_mode="basic"
ca_mode="project"
if [ -n "$CA_SRC" ]; then
  install_mode="custom"
  ca_mode="per-home"
fi
persist="off"
[ "$JCM_PERSIST" = "1" ] && persist="on"
installer_version="${JUNE_VERSION:-$(cat "$SRC_DIR/VERSION" 2>/dev/null || echo 0.5)}"
build_id="${JUNE_BUILD_ID:-$(cat "$SRC_DIR/BUILD_ID" 2>/dev/null || echo unknown)}"
install_ip="${JUNE_OVEN_IP:-}"
cat > "$UDA_MNT/june/install.json" <<EOF
{
  "mode": "$install_mode",
  "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "installer_version": "$installer_version",
  "build_id": "$build_id",
  "persistence": "$persist",
  "ca_mode": "$ca_mode",
  "hostname": "${hostname_value:-june}",
  "install_ip": "$install_ip",
  "components": {
    "june-local": "$(comp_sha "$BIN_SRC")",
    "june-camerad": "$(comp_sha "$CAMERAD_SRC")",
    "OvenLight": "$(comp_sha "$LIGHT_SRC")",
    "Chef": "$(comp_sha "$CHEF_SRC")",
    "JuneCloudMessaging": "$jcm_sha",
    "Remotes": "$(comp_sha "$REMOTES_SRC")",
    "MediaCapturer": "$(comp_sha "$MEDIACAPTURER_SRC")",
    "Analytics": "$(comp_sha "$ANALYTICS_SRC")"
  }
}
EOF
chmod 0644 "$UDA_MNT/june/install.json"
echo "[+] wrote /data/june/install.json ($install_mode, persistence $persist)"

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

if [ -n "$MEDIACAPTURER_SRC" ]; then
  if [ "$JCM_PERSIST" != "1" ]; then
    install -m 0644 "$MEDIACAPTURER_SRC" "$UDA_MNT/june/mediacapturer_nopin.apk"
    mc_dst_sha="$(sha256sum "$UDA_MNT/june/mediacapturer_nopin.apk" | awk '{print $1}')"
    mc_src_sha="$(sha256sum "$MEDIACAPTURER_SRC" | awk '{print $1}')"
    if [ "$mc_dst_sha" != "$mc_src_sha" ]; then
      echo "[-] /data MediaCapturer APK write mismatch" >&2
      echo "    src: $mc_src_sha" >&2
      echo "    dst: $mc_dst_sha" >&2
      exit 1
    fi
    echo "[+] non-persistent MediaCapturer patch staged in /data/june/mediacapturer_nopin.apk ($(stat -c '%s' "$MEDIACAPTURER_SRC") bytes)"
  else
    echo "[ ] persistent MediaCapturer patch staged in /system/etc/june/mediacapturer_nopin.apk"
  fi
else
  rm -f "$UDA_MNT/june/mediacapturer_nopin.apk"
fi

# Chef cook-modes patch. When it could not be persisted in both system
# partitions, stage a /data copy: june_reaper applies it on the next boot and
# removes the staged file afterwards. A persistent /system copy wins on the
# next boot; the /data copy stays as a post-factory-reset fallback.
if [ -n "$CHEF_SRC" ]; then
  if [ "${CHEF_PERSISTED:-0}" -ge 2 ]; then
    echo "[ ] Chef patch persisted in both system partitions; skipping /data staging"
  else
    chef_size="$(stat -c '%s' "$CHEF_SRC" 2>/dev/null || echo 0)"
    chef_need_kb=$(( ((chef_size + 1023) / 1024) * 2 + 65536 ))
    chef_avail_kb="$(df -Pk "$UDA_MNT" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [ "${chef_avail_kb:-0}" -ge "$chef_need_kb" ]; then
      install -m 0644 "$CHEF_SRC" "$UDA_MNT/june/chef_cookmodes.apk"
      chef_dst_sha="$(sha256sum "$UDA_MNT/june/chef_cookmodes.apk" | awk '{print $1}')"
      chef_src_sha="$(sha256sum "$CHEF_SRC" | awk '{print $1}')"
      if [ "$chef_dst_sha" != "$chef_src_sha" ]; then
        echo "[-] /data Chef APK write mismatch" >&2
        echo "    src: $chef_src_sha" >&2
        echo "    dst: $chef_dst_sha" >&2
        exit 1
      fi
      echo "[+] Chef patch staged in /data/june/chef_cookmodes.apk ($chef_size bytes; applied on next boot)"
    else
      echo "[!] not enough space on /data for the Chef patch (need $(( chef_need_kb / 1024 )) MB, have $(( ${chef_avail_kb:-0} / 1024 )) MB); cook modes stay stock" >&2
    fi
  fi
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
  sha256sum "$BIN_SRC" "$CAMERAD_SRC" "$CERT_SRC" "$KEY_SRC" "$JCM_SRC" "$BOOTCLEAR_SRC" "$JUNE_REAPER_SRC" "$COMPANION_STATE_SRC" "$BOOT_SRC" "$LIGHT_SRC" ${REMOTES_SRC:+"$REMOTES_SRC"} ${MEDIACAPTURER_SRC:+"$MEDIACAPTURER_SRC"} ${ANALYTICS_SRC:+"$ANALYTICS_SRC"} ${CHEF_SRC:+"$CHEF_SRC"}
else
  sha256sum "$BIN_SRC" "$CAMERAD_SRC" "$CERT_SRC" "$KEY_SRC" "$JCM_SRC" "$BOOTCLEAR_SRC" "$JUNE_REAPER_SRC" "$COMPANION_STATE_SRC" "$LIGHT_SRC" ${REMOTES_SRC:+"$REMOTES_SRC"} ${MEDIACAPTURER_SRC:+"$MEDIACAPTURER_SRC"} ${ANALYTICS_SRC:+"$ANALYTICS_SRC"} ${CHEF_SRC:+"$CHEF_SRC"}
fi
echo "[+] power-cycle the oven normally; the junelocal init service starts june-local at boot_completed."
