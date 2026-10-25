#!/usr/bin/env bash
# deploy_custom_via_adb.sh - apply the June Local custom-install payload over root ADB.
#
# WHY THIS EXISTS
#   The USB/ISO installer writes the payload by loop-mounting the oven's eMMC in
#   UMS mode (installer/onoven/deploy_onoven.sh). This script is the no-RCM,
#   no-open-box path for an oven that ALREADY runs the June Local boot image and
#   a root adbd: it stages the exact same payload files where the on-oven boot
#   scripts already look for them, then reboots so the June Local copy of
#   /system/bin/june_reaper.sh applies the app patches during the EncFS collector
#   mount, before Android starts.
#
# WHAT IT DOES NOT DO (deliberately)
#   * It never flashes a boot image and never uses RCM/fastboot/dd.
#   * It never factory-resets the oven and never touches pairing state.
#   * It never writes /data/system/users/0/accounts.db on the running oven: the
#     pre-Android june_reaper.sh identity ensure installs the account seed
#     before Android starts on the next boot, which is the only safe moment
#     (AccountManager has the live DB open while Android runs).
#   * It does not modify the running June Local scripts. It relies on them:
#     /system/bin/june_reaper.sh must be the June Local version (it contains
#     apply_staged_apk), and /system/xbin/june-local must be installed. If either
#     is missing the script aborts: this path can only re-apply the payload on a
#     system that already has the June Local boot image + patched scripts, it
#     cannot bootstrap them.
#
# WHAT IT WRITES (oven side)
#   /system/etc/june_leaf.crt                     leaf certificate + CA chain (0644)
#   /system/etc/june_leaf.key                     leaf private key (0600)
#   /system/etc/june_ca.crt                       per-home CA served at /local/ca.crt (0644)
#   /system/etc/security/cacerts/<hash.0>         same CA in the oven trust store (0644)
#   /system/etc/june_hostname                     mDNS name, only when --hostname is given (0644)
#   /data/june/jcm_nopin.apk                      patched JuneCloudMessaging, staged (0644)
#   /data/june/remotes_nopin.apk                  patched Remotes, staged (0644)
#   /data/june/mediacapturer_nopin.apk            patched MediaCapturer, staged (0644)
#   /data/june/install.json                       provenance consumed by /local/status
#   /system/etc/june/identity/token               per-oven v2: account token (0644)
#   /system/etc/june/identity/accounts_seed.db    AccountManager seed DB (0644)
#   /system/etc/june/identity/identity.json       identity record for the next boot (0644)
#   /data/june/identity.json                      runtime identity record (0600; preserved
#                                                 when its token matches, otherwise rewritten)
#   /data/june/backups/adb-deploy-<UTC>/          backups of every file it replaces
#
#   Stale /system/etc/june/{jcm,remotes,mediacapturer}_nopin.apk copies are backed
#   up and removed first: june_reaper prefers /system over /data staging paths, so
#   leaving an old persistent copy there would silently shadow this deploy.
#   /data/june/companions_state.json (the companion registry) is NEVER touched.
#
# PREREQUISITES
#   Oven:
#     * June Local boot image with root adbd, fully booted (sys.boot_completed=1)
#     * root adbd reachable from this host. USB: the internal USB/ADB port
#       (cable/service port). TCP: stock init sets service.adb.tcp.port 5555, so
#       try `adb connect <oven-ip>:5555` first and pass `--serial <oven-ip>:5555`.
#       This script assumes the device is already connected; it never runs
#       `adb connect` (or `adb root`).
#     * /system/xbin/june-local and the patched /system/bin/june_reaper.sh present
#     * `adb shell id` reports uid=0 (this script never runs `adb root`: on this
#       build restarting adbd that way drops the console instead of elevating it)
#   Host:
#     * bash 4+, adb, openssl, sha256sum (or shasum -a 256), coreutils
#       (python3 is used for JSON validation and to mint the identity seed when
#       the oven has no /system/etc/june/identity yet)
#     * CERT_DIR: ca.crt (self-signed per-home CA), leaf.crt or fullchain.crt,
#       and leaf.key
#     * APK_DIR: JuneCloudMessaging_nopin_signed.apk, Remotes_nopin_signed.apk,
#       MediaCapturer_nopin_signed.apk
#     * identity assets (only when seeding a fresh identity; not needed when the
#       oven already has /system/etc/june/identity/{token,accounts_seed.db}):
#       generate_identity.py + accounts_template.db, searched next to APK_DIR,
#       the script, the repo's installer/installer/liveiso/assets, and
#       /opt/june-installer, or passed with --identity-gen/--identity-template
#       (also $JUNE_IDENTITY_GEN/$JUNE_ACCOUNTS_TEMPLATE); plus python3.
#       Without them the script fails closed with the exact fix.
#
# USAGE
#   ./deploy_custom_via_adb.sh --cert-dir DIR [--apk-dir DIR] --install-ip IP \
#       [--hostname NAME] [--serial SERIAL] [--no-reboot] [--yes] \
#       [--allow-cert-warnings] [--identity-gen FILE] [--identity-template FILE] \
#       [--allow-identity-missing] [--installer-version V] [--build-id B]
#
#   --cert-dir DIR           directory with ca.crt, leaf.crt (or fullchain.crt),
#                            leaf.key (also settable via $CERT_DIR)
#   --apk-dir DIR            directory with the three no-pin APKs. Defaults to
#                            the cert directory's parent, then the script
#                            directory, then the ISO payload assets
#                            (also settable via $APK_DIR)
#   --install-ip IP          the oven's LAN IP at install time; written to
#                            install.json and checked against the leaf IP SAN
#                            (also settable via $JUNE_OVEN_IP)
#   --hostname NAME          oven mDNS name (without .local). Defaults to the
#                            name already on the oven, else "june". When given and
#                            different, /system/etc/june_hostname is updated and
#                            the leaf must cover the name
#   --serial SERIAL          adb device serial, required when several are attached
#                            (also settable via $ADB_SERIAL). For TCP ADB run
#                            `adb connect <oven-ip>:5555` first and pass
#                            `--serial <oven-ip>:5555`.
#   --no-reboot              stage everything but do not reboot
#   --yes                    skip the interactive confirmation
#   --allow-cert-warnings    proceed despite certificate/SAN problems that would
#                            make /local show amber/red problems (no IP SAN, IP
#                            not in SAN, hostname not in SAN). Off by default.
#   --identity-gen FILE      generate_identity.py from the installer payload
#                            (default: $JUNE_IDENTITY_GEN, searched next to the
#                            payload; needed only when the oven has no identity)
#   --identity-template FILE accounts_template.db from the installer payload
#                            (default: $JUNE_ACCOUNTS_TEMPLATE, same search)
#   --allow-identity-missing deploy certs/APKs even when the oven has no
#                            /system identity seed and no assets to mint one.
#                            Not recommended: /local still reports
#                            identity-missing and factory reset cannot self-heal.
#   --installer-version V    installer_version recorded in install.json (default:
#                            VERSION next to the payload, else "unknown")
#   --build-id B             build_id recorded in install.json (default: BUILD_ID
#                            next to the payload, else "unknown")
#
# PER-OVEN IDENTITY (why this matters)
#   A factory reset wipes /data/system/users/0/accounts.db; without the June
#   account row the JuneCloudMessaging app never attaches a bearer token and the
#   oven looks "disconnected" even though the install is fine. The June Local
#   installer therefore puts a per-oven token + AccountManager seed in
#   /system/etc/june/identity, which survives a reset, and the patched
#   june_reaper.sh installs that seed before Android starts when the row is
#   missing. The UMS installer pre-seeds it; this ADB path adds the same flow:
#     * if /system/etc/june/identity/{token,accounts_seed.db} exist and the
#       token is a valid v2: token, they are preserved (only the identity record
#       is regenerated for the current endpoint);
#     * otherwise a fresh v2: token is minted (reusing an existing valid token
#       when only the seed is missing) and accounts_seed.db is built from the
#       schema template; both are pushed to /system. If the generator/template
#       or python3 is unavailable the script fails closed before writing
#       anything, printing the exact fix (payload paths / run the USB installer
#       once / --allow-identity-missing);
#     * /data/june/identity.json is preserved when it already carries the same
#       token, rewritten 0600 when its token differs (so /local's runtime token
#       matches the /system seed that survives a reset), or written 0600 when
#       absent. The previous record is always backed up as data-identity.json;
#     * install.json gets the hash-only identity block
#       {account_present, seed_source, token_sha256_prefix};
#     * `setprop june.local.token` is set only when a JCM patch is staged, which
#       is the only consumer of that property (the same rule june_reaper uses).
#   The token itself is written only to /system/etc/june/identity/token and the
#   identity records, never to install.json or the screen.
#
#   Scope note: over ADB this seeds the RUNNING /system (the APP slot). A hard
#   factory reset restores APP from SAP, so that slot also needs the seed for
#   post-reset self-heal; the USB/ISO installer writes both slots (this script
#   never touches SAP). Seeding the running system still fixes /local/status
#   immediately and keeps the account row across normal boots.
#
# EXIT STATUS
#   0  payload staged (and reboot issued unless --no-reboot)
#   1  any prerequisite, safety or verification check failed; the script prints
#      what failed and how to restore from the backup directory
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Fixed oven-side paths
# ---------------------------------------------------------------------------
SYS_ETC="/system/etc"
LEAF_CRT="$SYS_ETC/june_leaf.crt"
LEAF_KEY="$SYS_ETC/june_leaf.key"
CA_CRT="$SYS_ETC/june_ca.crt"
HOSTNAME_FILE="$SYS_ETC/june_hostname"
CACERTS_DIR="$SYS_ETC/security/cacerts"
STAGE_DIR="$SYS_ETC/june"
DATA_DIR="/data/june"
INSTALL_JSON="$DATA_DIR/install.json"
COMPANIONS_JSON="$DATA_DIR/companions_state.json"
REAPER="/system/bin/june_reaper.sh"
JUNE_LOCAL="/system/xbin/june-local"
BB="/system/bin/busybox"

# Per-oven June account identity (survives a factory reset because it lives on
# /system; june_reaper.sh installs the seed into /data before Android starts).
ID_DIR="$SYS_ETC/june/identity"
ID_TOKEN="$ID_DIR/token"
ID_SEED="$ID_DIR/accounts_seed.db"
ID_JSON="$ID_DIR/identity.json"
DATA_ID_JSON="$DATA_DIR/identity.json"
ACCOUNTS_DB="/data/system/users/0/accounts.db"
JUNE_TOKEN_PROP="june.local.token"

# The three no-pin APKs this path stages. These are the exact filenames the
# custom install flow passes to deploy_onoven.sh.
JCM_APK_NAME="JuneCloudMessaging_nopin_signed.apk"
REMOTES_APK_NAME="Remotes_nopin_signed.apk"
MEDIA_APK_NAME="MediaCapturer_nopin_signed.apk"

# Staging destinations june_reaper.sh reads at boot (see june_reaper.sh.junelocal).
JCM_STAGE="$DATA_DIR/jcm_nopin.apk"
REMOTES_STAGE="$DATA_DIR/remotes_nopin.apk"
MEDIA_STAGE="$DATA_DIR/mediacapturer_nopin.apk"

# Persistent staging paths that would take priority over the /data copies above.
STALE_STAGES="$STAGE_DIR/jcm_nopin.apk $STAGE_DIR/remotes_nopin.apk $STAGE_DIR/mediacapturer_nopin.apk"

# ---------------------------------------------------------------------------
# Options and state
# ---------------------------------------------------------------------------
CERT_DIR="${CERT_DIR:-}"
APK_DIR="${APK_DIR:-}"
INSTALL_IP="${JUNE_OVEN_IP:-}"
OVEN_HOST="${OVEN_HOST:-}"
SERIAL="${ADB_SERIAL:-}"
INSTALLER_VERSION="${JUNE_VERSION:-}"
BUILD_ID="${JUNE_BUILD_ID:-}"
IDENTITY_GEN="${JUNE_IDENTITY_GEN:-}"
IDENTITY_TEMPLATE="${JUNE_ACCOUNTS_TEMPLATE:-}"
PYTHON="${PYTHON:-}"
ALLOW_CERT_WARNINGS=0
ALLOW_IDENTITY_MISSING=0
ASSUME_YES=0
DO_REBOOT=1
WAIT_ADB_SECS="${JUNE_WAIT_ADB_SECS:-60}"
WAIT_BOOT_SECS="${JUNE_WAIT_BOOT_SECS:-180}"
DISK_MARGIN_KB=32768

PROG="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ADB_BASE=("adb")
ADB=("${ADB_BASE[@]}")
ADB_READY=0
SYSTEM_RW=0
TMP_DIR=""
BACKUP_DIR=""
INSTALL_JSON_LOCAL=""
HOSTNAME_TMP=""
DEV_HOST=""
EXISTING_JSON=""
DEV_MODEL=""
DEV_IP=""
COMPANIONS_BEFORE=""
COMPANIONS_AFTER=""
HOSTNAME_CHANGED=0
VERIFY_ERRORS=0
SHA_CMD=()
CHAIN_FILE=""
LEAF_PEM=""
CA_PEM=""
CA_HASH=""
SAN_ITEMS=""
HAS_IP_SAN=0
IP_IN_SAN=0
HOST_IN_SAN=0
LEAF_FP=""
CA_FP=""
PAYLOAD_BYTES=0

# Component hashes recorded in /data/june/install.json. The first four are
# preserved from the existing install.json (or inferred from the running system
# for components this path does not replace); the three patched apps always get
# the hash of the APK staged here.
C_JUNE_LOCAL=""
C_CAMERAD=""
C_OVENLIGHT=""
C_CHEF=""
C_ANALYTICS=""
JCM_SHA=""
REMOTES_SHA=""
MEDIA_SHA=""
CHAIN_SHA=""
KEY_SHA=""
CA_SHA=""
JCM_BYTES=0
REMOTES_BYTES=0
MEDIA_BYTES=0

# Per-oven identity state, filled in by collect_identity_state (device probe)
# and prepare_identity_assets (host-side mint/build), used by push_identity,
# build_install_json and the final report.
IDENTITY_MODE=""
IDENTITY_TOKEN=""
EXISTING_ID_TOKEN=""
IDENTITY_TOKEN_SHA=""
IDENTITY_SEED_SOURCE="unavailable"
IDENTITY_SEED_LOCAL=""
IDENTITY_JSON_LOCAL=""
IDENTITY_TOKEN_FILE_LOCAL=""
PYTHON_BIN=""
SYS_IDENTITY_PRESENT=0
IDENTITY_SEED_PRESENT=0
DATA_IDENTITY_EXISTS=0
DATA_ID_TOKEN=""
DATA_ID_ALIGNED=0
DATA_ID_REWRITTEN=0
ACCOUNT_PRESENT="false"
JCM_STAGED=0
JCM_PROP_SET=0

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
step() { printf '\n== %s ==\n' "$*"; }
say()  { printf '[*] %s\n' "$*"; }
note() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() {
  local m="$1"; shift
  local l
  printf '[-] %s\n' "$m" >&2
  for l in "$@"; do
    printf '    %s\n' "$l" >&2
  done
  exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
  local rc="$?"
  set +e
  if [ "${SYSTEM_RW:-0}" = "1" ] && [ "${ADB_READY:-0}" = "1" ]; then
    "${ADB[@]}" shell 'sync' >/dev/null 2>&1
    "${ADB[@]}" shell 'mount -o ro,remount /system' >/dev/null 2>&1
  fi
  if [ -n "${TMP_DIR:-}" ] && [ -d "${TMP_DIR:-}" ]; then
    rm -rf "$TMP_DIR"
  fi
  exit "$rc"
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Apply the June Local custom-install payload to an oven that already runs the
June Local boot image and root ADB (adb shell id -> uid=0).

  deploy_custom_via_adb.sh --cert-dir DIR [--apk-dir DIR] --install-ip IP
      [--hostname NAME] [--serial SERIAL] [--no-reboot] [--yes]
      [--allow-cert-warnings] [--identity-gen FILE] [--identity-template FILE]
      [--allow-identity-missing] [--installer-version V] [--build-id B]

  --cert-dir DIR          ca.crt, leaf.crt or fullchain.crt, leaf.key
  --apk-dir DIR           JuneCloudMessaging_nopin_signed.apk,
                          Remotes_nopin_signed.apk, MediaCapturer_nopin_signed.apk
                          (default: cert dir's parent, script dir, or ISO assets)
  --install-ip IP         oven LAN IP at install time (also $JUNE_OVEN_IP)
  --hostname NAME         mDNS oven name, without .local
  --serial SERIAL         adb serial when more than one device is attached
  --no-reboot             stage the payload but do not reboot
  --yes                   do not ask for confirmation
  --allow-cert-warnings   continue despite cert/SAN mismatches (not recommended)
  --identity-gen FILE     generate_identity.py for minting the account seed
                          (default: $JUNE_IDENTITY_GEN, searched next to the payload)
  --identity-template FILE accounts_template.db for minting the account seed
                          (default: $JUNE_ACCOUNTS_TEMPLATE, same search)
  --allow-identity-missing continue even when the oven has no identity seed and
                          no assets to mint one (factory reset will not self-heal)
  --installer-version V   installer_version for install.json
  --build-id B            build_id for install.json
  -h, --help              this text

When /system/etc/june/identity/{token,accounts_seed.db} is missing this script
mints a fresh v2: token and builds the AccountManager seed from the installer's
schema template, so the patched june_reaper.sh can restore the June account
before Android starts (needed for the oven to stay connected after a factory
reset). Without the generator/template the script fails closed before writing,
pointing at the installer payload assets or the USB installer.

The oven must be fully booted with the June Local boot image (root adbd) and
the internal USB/ADB port accessible. This script does NOT flash a boot image,
does NOT use RCM, and does NOT factory-reset the oven.
USAGE
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
host_sha() {
  "${SHA_CMD[@]}" "$1" | awk '{print $1}'
}

# sh_run CMD: run CMD through adb shell, capture stdout in SH_OUT and the remote
# exit status in SH_RC. A marker line is appended so this works with adb versions
# that do not propagate remote exit codes. Output is filtered of CR (Windows adb).
SH_OUT=""
SH_RC=0
sh_run() {
  local raw marker rc
  raw="$("${ADB[@]}" shell "$1; __june_rc=\$?; printf '\n__JUNE_RC=%s\n' \"\$__june_rc\"" 2>&1)" || true
  raw="$(printf '%s' "$raw" | tr -d '\r')"
  marker="$(printf '%s\n' "$raw" | awk '/^__JUNE_RC=/{sub(/^__JUNE_RC=/, ""); m=$0} END{print m}')"
  SH_OUT="$(printf '%s\n' "$raw" | awk '!/^__JUNE_RC=/' | sed -e '/^$/d')"
  rc="${marker:-127}"
  case "$rc" in
    ''|*[!0-9]*) rc=127 ;;
  esac
  SH_RC="$rc"
  [ "$rc" -eq 0 ]
}

remote_exists() {
  sh_run "[ -f $1 ]"
}

remote_size() {
  local p="$1" v=""
  if sh_run "$BB stat -c '%s' $p"; then
    v="$(printf '%s' "$SH_OUT" | tr -d ' \t')"
  fi
  case "$v" in
    ''|*[!0-9]*) v="" ;;
  esac
  printf '%s' "$v"
}

dev_sha() {
  local p="$1" h=""
  if sh_run "$BB sha256sum $p"; then
    h="$(printf '%s\n' "$SH_OUT" | awk 'NR==1{print $1}')"
  fi
  case "$h" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) printf '%s' "$h" ;;
    *) printf '' ;;
  esac
}

dev_mode() {
  local p="$1" m=""
  if sh_run "$BB stat -c '%a' $p"; then
    m="$(printf '%s' "$SH_OUT" | tr -d ' \t')"
  fi
  printf '%s' "$m"
}

system_is_rw() {
  if ! sh_run 'cat /proc/mounts'; then
    return 1
  fi
  printf '%s\n' "$SH_OUT" | awk '$2=="/system" { if ($4 ~ /(^|,)rw($|,)/) found=1 } END { exit(found ? 0 : 1) }'
}

# df_avail_kb PATH: device free blocks on PATH in KiB, or empty on failure.
df_avail_kb() {
  if ! sh_run "$BB df -k $1"; then
    return 0
  fi
  printf '%s\n' "$SH_OUT" | awk 'NF>=6 { v=$4 } END { print v }'
}

# json_comp FILE KEY: 64-hex component hash for KEY in an existing install.json,
# or empty. Local-only (the file was pulled earlier); values are hex so a simple
# extraction is safe.
json_comp() {
  local f="$1" k="$2" raw v=""
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    printf ''
    return 0
  fi
  raw="$(grep -o "\"$k\"[[:space:]]*:[[:space:]]*\"[0-9a-fA-F]*\"" "$f" 2>/dev/null | awk 'NR==1')" || true
  if [ -n "$raw" ]; then
    v="$(printf '%s' "$raw" | sed -e 's/^[^:]*:[[:space:]]*"//' -e 's/"$//')"
  fi
  case "$v" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) printf '%s' "$v" ;;
    *) printf '' ;;
  esac
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --cert-dir)
        [ "$#" -ge 2 ] || die "--cert-dir needs a directory argument"
        CERT_DIR="$2"; shift 2 ;;
      --apk-dir)
        [ "$#" -ge 2 ] || die "--apk-dir needs a directory argument"
        APK_DIR="$2"; shift 2 ;;
      --install-ip)
        [ "$#" -ge 2 ] || die "--install-ip needs an IPv4 argument"
        INSTALL_IP="$2"; shift 2 ;;
      --hostname)
        [ "$#" -ge 2 ] || die "--hostname needs a name argument"
        OVEN_HOST="$2"; shift 2 ;;
      --serial)
        [ "$#" -ge 2 ] || die "--serial needs a serial argument"
        SERIAL="$2"; shift 2 ;;
      --installer-version)
        [ "$#" -ge 2 ] || die "--installer-version needs a value"
        INSTALLER_VERSION="$2"; shift 2 ;;
      --build-id)
        [ "$#" -ge 2 ] || die "--build-id needs a value"
        BUILD_ID="$2"; shift 2 ;;
      --identity-gen)
        [ "$#" -ge 2 ] || die "--identity-gen needs a file argument"
        IDENTITY_GEN="$2"; shift 2 ;;
      --identity-template)
        [ "$#" -ge 2 ] || die "--identity-template needs a file argument"
        IDENTITY_TEMPLATE="$2"; shift 2 ;;
      --allow-identity-missing)
        ALLOW_IDENTITY_MISSING=1; shift ;;
      --allow-cert-warnings)
        ALLOW_CERT_WARNINGS=1; shift ;;
      --yes|-y)
        ASSUME_YES=1; shift ;;
      --no-reboot)
        DO_REBOOT=0; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        die "unknown argument: $1" "Run $PROG --help for usage." ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Host prerequisites and payload validation
# ---------------------------------------------------------------------------
host_checks() {
  local c
  for c in adb openssl sed awk grep tr mktemp head cat cp rm wc sleep date dirname cmp; do
    have "$c" || die "required host command not found: $c" \
      "This script runs on the install host (the machine the oven's USB/ADB port is plugged into)."
  done
  if have sha256sum; then
    SHA_CMD=(sha256sum)
  elif have shasum; then
    SHA_CMD=(shasum -a 256)
  else
    die "no SHA-256 tool found (need sha256sum or shasum)." \
      "sha256sum is required to record and verify payload hashes."
  fi
  if ! openssl x509 -help >/dev/null 2>&1; then
    die "openssl is not usable on this host." \
      "openssl x509 is needed to verify the chain and compute subject_hash_old."
  fi
  case "$WAIT_ADB_SECS" in
    ''|*[!0-9]*) WAIT_ADB_SECS=60 ;;
  esac
  case "$WAIT_BOOT_SECS" in
    ''|*[!0-9]*) WAIT_BOOT_SECS=180 ;;
  esac
}

pad_path() {
  if [ -z "$CERT_DIR" ]; then
    die "no certificate directory given." \
      "Use --cert-dir DIR (or set CERT_DIR)." \
      "CERT_DIR must contain: ca.crt, leaf.crt (or fullchain.crt) and leaf.key" \
      "for the per-home CA install (generate them with the installer's" \
      "installer/installer/liveiso/assets/generate_certs.sh)."
  fi
  if [ ! -d "$CERT_DIR" ]; then
    die "certificate directory not found: $CERT_DIR"
  fi
  if [ -z "$APK_DIR" ]; then
    local d="$CERT_DIR" t
    t="${d%/*}"
    if [ "$t" = "$d" ]; then
      t="."
    fi
    if [ -f "$t/$JCM_APK_NAME" ] && [ -f "$t/$REMOTES_APK_NAME" ] && [ -f "$t/$MEDIA_APK_NAME" ]; then
      APK_DIR="$t"
    elif [ -f "$SCRIPT_DIR/$JCM_APK_NAME" ] && [ -f "$SCRIPT_DIR/$REMOTES_APK_NAME" ] && [ -f "$SCRIPT_DIR/$MEDIA_APK_NAME" ]; then
      APK_DIR="$SCRIPT_DIR"
    else
      APK_DIR="$SCRIPT_DIR/../installer/liveiso/assets"
    fi
  fi
  if [ ! -d "$APK_DIR" ]; then
    die "payload APK directory not found: $APK_DIR" \
      "Use --apk-dir DIR (or set APK_DIR)."
  fi
  if [ -z "$INSTALL_IP" ]; then
    die "no oven IP given." \
      "Use --install-ip IP (or set JUNE_OVEN_IP). It is recorded in" \
      "install.json and checked against the leaf certificate's IP SAN."
  fi
  validate_ip "$INSTALL_IP"
  if [ -n "$OVEN_HOST" ]; then
    normalize_host "$OVEN_HOST"
    OVEN_HOST="$NORMALIZED_HOST"
  fi
  if [ -z "$INSTALLER_VERSION" ]; then
    INSTALLER_VERSION="$(read_meta VERSION)"
  fi
  if [ -z "$BUILD_ID" ]; then
    BUILD_ID="$(read_meta BUILD_ID)"
  fi
  sanitize_meta
}

# read_meta NAME: first line of NAME next to the payload assets, else "unknown".
read_meta() {
  local n="$1" f v=""
  for f in "$APK_DIR/$n" "$SCRIPT_DIR/../installer/liveiso/assets/$n"; do
    if [ -n "$f" ] && [ -f "$f" ]; then
      v="$(sed -n '1p' "$f" | tr -d '\r\n')"
      if [ -n "$v" ]; then
        break
      fi
    fi
  done
  [ -n "$v" ] || v="unknown"
  printf '%s' "$v"
}

sanitize_meta() {
  case "$INSTALLER_VERSION" in
    ''|*[!A-Za-z0-9._+-]*) INSTALLER_VERSION="unknown" ;;
  esac
  case "$BUILD_ID" in
    ''|*[!A-Za-z0-9._+-]*) BUILD_ID="unknown" ;;
  esac
}

validate_ip() {
  local ip="$1" o
  local old_ifs="$IFS"
  if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    IFS="$old_ifs"
    die "invalid --install-ip value: $ip" "Expected dotted IPv4, e.g. 192.168.1.100."
  fi
  IFS='.'
  for o in $ip; do
    if [ "$((10#$o))" -gt 255 ]; then
      IFS="$old_ifs"
      die "invalid --install-ip value: $ip" "Each octet must be 0-255."
    fi
  done
  IFS="$old_ifs"
}

NORMALIZED_HOST=""
normalize_host() {
  local h="$1"
  h="${h%.local}"
  if [ -z "$h" ]; then
    die "empty --hostname value" "Pass a name such as june or kitchen-oven."
  fi
  if [[ ! "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]; then
    die "invalid --hostname value: $1" \
      "Use letters, digits, dot, dash and underscore (no spaces, no leading dash)."
  fi
  if [ "${#h}" -gt 63 ]; then
    die "invalid --hostname value: $1" "Keep it to 63 characters or fewer."
  fi
  NORMALIZED_HOST="$h"
}

preflight_certs() {
  local leaf_src="" f v out
  if [ -f "$CERT_DIR/leaf.crt" ]; then
    leaf_src="$CERT_DIR/leaf.crt"
  elif [ -f "$CERT_DIR/fullchain.crt" ]; then
    leaf_src="$CERT_DIR/fullchain.crt"
  else
    die "no leaf certificate in $CERT_DIR" \
      "Expected leaf.crt (or fullchain.crt) plus ca.crt and leaf.key."
  fi
  if [ ! -f "$CERT_DIR/ca.crt" ]; then
    die "no CA certificate in $CERT_DIR (need ca.crt)."
  fi
  if [ ! -f "$CERT_DIR/leaf.key" ]; then
    die "no leaf private key in $CERT_DIR (need leaf.key)."
  fi
  LEAF_PEM="$TMP_DIR/leaf.pem"
  CA_PEM="$TMP_DIR/ca.pem"
  if ! out="$(openssl x509 -in "$leaf_src" -out "$LEAF_PEM" 2>&1)"; then
    die "the leaf certificate does not parse: $leaf_src" "$out"
  fi
  if ! out="$(openssl x509 -in "$CERT_DIR/ca.crt" -out "$CA_PEM" 2>&1)"; then
    die "the CA certificate does not parse: $CERT_DIR/ca.crt" "$out"
  fi

  case "$(sed -n '1p' "$CERT_DIR/leaf.key")" in
    *"ENCRYPTED PRIVATE KEY"*)
      die "leaf.key is encrypted; the on-oven server needs an unencrypted key." \
        "Decrypt it (openssl pkey -in leaf.key -out leaf-plain.key) and retry." ;;
  esac

  if ! openssl pkey -in "$CERT_DIR/leaf.key" -pubout -passin pass: -out "$TMP_DIR/key.pub" >/dev/null 2>&1; then
    openssl rsa -in "$CERT_DIR/leaf.key" -pubout -passin pass: -out "$TMP_DIR/key.pub" >/dev/null 2>&1 \
      || die "could not read the private key: $CERT_DIR/leaf.key"
  fi
  if ! openssl x509 -in "$LEAF_PEM" -noout -pubkey > "$TMP_DIR/leaf.pub" 2>/dev/null; then
    die "could not extract the public key from the leaf certificate."
  fi
  if ! cmp -s "$TMP_DIR/key.pub" "$TMP_DIR/leaf.pub"; then
    die "leaf.key does not match the leaf certificate." \
      "ca.crt / leaf.crt / leaf.key in $CERT_DIR are not from the same issuance."
  fi

  local ca_subj ca_issuer
  ca_subj="$(openssl x509 -in "$CA_PEM" -noout -subject 2>/dev/null || true)"
  ca_issuer="$(openssl x509 -in "$CA_PEM" -noout -issuer 2>/dev/null || true)"
  if [ -z "$ca_subj" ] || [ "$ca_subj" != "$ca_issuer" ]; then
    die "ca.crt is not a self-signed CA." \
      "The custom install uses a per-home CA that is installed into the oven's" \
      "system trust store, so ca.crt must be a self-signed root." \
      "subject: $ca_subj" \
      "issuer:  $ca_issuer"
  fi
  if ! openssl x509 -in "$CA_PEM" -noout -text 2>/dev/null | grep -q 'CA:TRUE'; then
    die "ca.crt does not have basicConstraints CA:TRUE."
  fi
  if ! out="$(openssl verify -CAfile "$CA_PEM" "$LEAF_PEM" 2>&1)"; then
    die "the leaf certificate does not chain to ca.crt." \
      "Re-issue the certs together (generate_certs.sh) and retry." \
      "$out"
  fi

  if ! openssl x509 -in "$LEAF_PEM" -noout -checkend 0 >/dev/null 2>&1; then
    die "the leaf certificate has expired." \
      "Re-run the custom cert generation and retry."
  fi
  if ! openssl x509 -in "$CA_PEM" -noout -checkend 0 >/dev/null 2>&1; then
    die "the CA certificate has expired." \
      "Re-run the custom cert generation and retry."
  fi
  if ! openssl x509 -in "$LEAF_PEM" -noout -checkend 2592000 >/dev/null 2>&1; then
    warn "the leaf certificate expires within 30 days; /local will show an amber problem."
  fi

  CA_HASH="$(openssl x509 -in "$CA_PEM" -noout -subject_hash_old 2>/dev/null || true)"
  case "$CA_HASH" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *)
      die "openssl could not compute -subject_hash_old for ca.crt." \
        "Android names system-store CAs <subject_hash_old>.0; openssl 1.0+ is required."
      ;;
  esac

  if [ -f "$CERT_DIR/fullchain.crt" ]; then
    CHAIN_FILE="$CERT_DIR/fullchain.crt"
  else
    CHAIN_FILE="$TMP_DIR/fullchain.crt"
    cat "$LEAF_PEM" "$CA_PEM" > "$CHAIN_FILE"
  fi
  LEAF_FP="$(openssl x509 -in "$LEAF_PEM" -noout -fingerprint -sha256 2>/dev/null || true)"
  local chain_fp
  chain_fp="$(openssl x509 -in "$CHAIN_FILE" -noout -fingerprint -sha256 2>/dev/null || true)"
  if [ -z "$LEAF_FP" ] || [ "$LEAF_FP" != "$chain_fp" ]; then
    die "the chain to serve does not start with the leaf certificate." \
      "$CHAIN_FILE must be leaf.crt followed by ca.crt (fullchain.crt)."
  fi
  CA_FP="$(openssl x509 -in "$CA_PEM" -noout -fingerprint -sha256 2>/dev/null || true)"
  local chain_certs
  chain_certs="$(grep -c 'BEGIN CERTIFICATE' "$CHAIN_FILE" 2>/dev/null || true)"
  case "$chain_certs" in
    ''|*[!0-9]*) chain_certs=0 ;;
  esac
  if [ "$chain_certs" -lt 2 ]; then
    warn "the chain to serve contains only $chain_certs certificate(s)." \
      "deploy_onoven.sh serves leaf + CA; clients without the CA installed" \
      "will fail TLS. Put ca.crt into fullchain.crt (generate_certs.sh does" \
      "this) or install the CA on the client."
  fi

  local san_line
  san_line="$(openssl x509 -in "$LEAF_PEM" -noout -text 2>/dev/null \
    | awk '/X509v3 Subject Alternative Name/{getline; print; exit}')"
  SAN_ITEMS="$(printf '%s' "$san_line" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [ -n "$SAN_ITEMS" ] && printf '%s\n' "$SAN_ITEMS" | grep -q '^IP Address:'; then
    HAS_IP_SAN=1
  fi
  if printf '%s\n' "$SAN_ITEMS" | grep -qx "IP Address:$INSTALL_IP"; then
    IP_IN_SAN=1
  fi
  local cand
  for cand in "$OVEN_HOST" "$OVEN_HOST.local"; do
    if [ -n "$cand" ] && printf '%s\n' "$SAN_ITEMS" | grep -qx "DNS:$cand"; then
      HOST_IN_SAN=1
    fi
  done

  if [ "$HAS_IP_SAN" -ne 1 ]; then
    if [ "$ALLOW_CERT_WARNINGS" -ne 1 ]; then
      die "the leaf certificate has no IP SAN." \
        "/local would report cert.has_ip_san=false and clients that use the" \
        "oven's IP address would fail TLS." \
        "Re-issue the certs with JUNE_IP_SAN=$INSTALL_IP (generate_certs.sh)," \
        "or re-run with --allow-cert-warnings to accept it."
    fi
    warn "the leaf certificate has no IP SAN (accepted due to --allow-cert-warnings)."
  fi
  if [ "$HAS_IP_SAN" -eq 1 ] && [ "$IP_IN_SAN" -ne 1 ]; then
    if [ "$ALLOW_CERT_WARNINGS" -ne 1 ]; then
      die "the leaf certificate does not cover --install-ip $INSTALL_IP." \
        "SANs: $SAN_ITEMS" \
        "Re-issue the certs with JUNE_IP_SAN=$INSTALL_IP, or re-run with" \
        "--allow-cert-warnings if the oven's IP will be different on purpose."
    fi
    warn "the leaf certificate does not cover --install-ip $INSTALL_IP (accepted)."
  fi
  if [ -n "$OVEN_HOST" ] && [ "$HOST_IN_SAN" -ne 1 ]; then
    if [ "$ALLOW_CERT_WARNINGS" -ne 1 ]; then
      die "the leaf certificate does not cover hostname $OVEN_HOST." \
        "SANs: $SAN_ITEMS" \
        "Re-issue the certs with JUNE_HOSTNAME=$OVEN_HOST, or pass a different" \
        "--hostname, or re-run with --allow-cert-warnings."
    fi
    warn "the leaf certificate does not cover hostname $OVEN_HOST (accepted)."
  fi

  say "leaf:   ${leaf_src##*/} ($LEAF_FP)"
  say "CA:     ca.crt in $CERT_DIR ($CA_HASH.0, $CA_FP)"
  say "SANs:   $SAN_ITEMS"
  say "key:    matches the leaf certificate"
}

preflight_apks() {
  local n f sz magic
  for n in "$JCM_APK_NAME" "$REMOTES_APK_NAME" "$MEDIA_APK_NAME"; do
    f="$APK_DIR/$n"
    if [ ! -f "$f" ]; then
      die "missing payload APK: $f" \
        "APK_DIR=$APK_DIR must contain all three no-pin APKs:" \
        "  $JCM_APK_NAME" "  $REMOTES_APK_NAME" "  $MEDIA_APK_NAME"
    fi
    sz="$(wc -c < "$f" | tr -d ' ')"
    case "$sz" in
      ''|*[!0-9]*) sz=0 ;;
    esac
    if [ "$sz" -lt 1000000 ]; then
      die "payload APK looks too small: $f ($sz bytes)" \
        "This is not a usable APK; re-copy the patched payload."
    fi
    magic="$(head -c 2 "$f")"
    if [ "$magic" != "PK" ]; then
      die "payload APK is not a ZIP/APK: $f" "First bytes: $magic (expected PK)."
    fi
  done
  JCM_BYTES="$(wc -c < "$APK_DIR/$JCM_APK_NAME" | tr -d ' ')"
  REMOTES_BYTES="$(wc -c < "$APK_DIR/$REMOTES_APK_NAME" | tr -d ' ')"
  MEDIA_BYTES="$(wc -c < "$APK_DIR/$MEDIA_APK_NAME" | tr -d ' ')"
  JCM_SHA="$(host_sha "$APK_DIR/$JCM_APK_NAME")"
  REMOTES_SHA="$(host_sha "$APK_DIR/$REMOTES_APK_NAME")"
  MEDIA_SHA="$(host_sha "$APK_DIR/$MEDIA_APK_NAME")"
  note "payload APKs: $JCM_APK_NAME $JCM_SHA"
  note "              $REMOTES_APK_NAME $REMOTES_SHA"
  note "              $MEDIA_APK_NAME $MEDIA_SHA"
}

# ---------------------------------------------------------------------------
# Device selection and readiness
# ---------------------------------------------------------------------------
select_device() {
  local waited=0 listing ready other count
  if [ -n "$SERIAL" ]; then
    ADB=("${ADB_BASE[@]}" "-s" "$SERIAL")
    say "using adb serial $SERIAL"
  else
    ADB=("${ADB_BASE[@]}")
  fi

  while [ "$waited" -lt "$WAIT_ADB_SECS" ]; do
    if [ -n "$SERIAL" ]; then
      if sh_run 'getprop sys.boot_completed' && [ "$(printf '%s' "$SH_OUT" | tr -d ' \t')" = "1" ]; then
        ADB_READY=1
        return 0
      fi
    else
      listing="$("${ADB_BASE[@]}" devices 2>/dev/null | tr -d '\r')" || listing=""
      ready="$(printf '%s\n' "$listing" | awk 'NR>1 && $2=="device" {print $1}')"
      other="$(printf '%s\n' "$listing" | awk 'NR>1 && NF>=2 && $2!="device" {print $1" ("$2")"}')"
      count="$(printf '%s\n' "$ready" | grep -c . 2>/dev/null || true)"
      case "$count" in
        ''|*[!0-9]*) count=0 ;;
      esac
      if [ "$count" -eq 1 ]; then
        SERIAL="$ready"
        ADB=("${ADB_BASE[@]}" "-s" "$SERIAL")
        ADB_READY=1
        return 0
      fi
      if [ "$count" -gt 1 ]; then
        die "more than one adb device is attached." \
          "$(printf '%s\n' "$ready")" \
          "Re-run with --serial SERIAL to pick the oven."
      fi
      if [ -n "$other" ]; then
        die "an adb device is attached but not ready: $other" \
          "If it says 'unauthorized', accept the USB debugging prompt on the oven" \
          "or make sure the boot image's adbd is the debug build." \
          "If it says 'offline', unplug/replug the internal USB cable."
      fi
    fi
    sleep 3
    waited=$((waited + 3))
  done

  die "no ADB device found after ${WAIT_ADB_SECS}s." \
    "The oven's internal USB/ADB port must be accessible before this script can run:" \
    "  * the oven must be running the June Local boot image (root adbd), fully booted;" \
    "  * the internal USB port (and any cable/hub used to reach it) must be plugged in;" \
    "  * or, if adbd is on TCP, run: adb connect <oven-ip>:5555" \
    "    then re-run with: --serial <oven-ip>:5555" \
    "  * 'adb devices' must list exactly one device in state 'device'." \
    "This script cannot enter RCM, cannot flash a boot image and cannot enable ADB" \
    "on a stock oven - that still needs the USB/ISO installer. Nothing was changed."
}

wait_for_boot() {
  local waited=0 v
  while [ "$waited" -lt "$WAIT_BOOT_SECS" ]; do
    if sh_run 'getprop sys.boot_completed'; then
      v="$(printf '%s' "$SH_OUT" | tr -d ' \t')"
      if [ "$v" = "1" ]; then
        return 0
      fi
    fi
    sleep 5
    waited=$((waited + 5))
  done
  die "the oven did not finish booting within ${WAIT_BOOT_SECS}s (sys.boot_completed != 1)." \
    "Wait for the oven UI to come up, then re-run. If it never boots, power-cycle" \
    "the oven and check the boot image / collector mount."
}

check_oven() {
  local out
  if ! sh_run 'id'; then
    die "adb shell is not answering on this device." \
      "Unplug/replug the internal USB cable and re-run."
  fi
  if ! printf '%s' "$SH_OUT" | grep -Eq '(^|[[:space:]])uid=0([^0-9]|$)'; then
    die "adb shell is not root (id -> $SH_OUT)." \
      "This path needs the June Local boot image's root adbd. It does not run" \
      "'adb root' (on this build that restarts adbd and closes the console)," \
      "and it cannot grant root on a stock system." \
      "Install the root-ADB boot image with the USB installer first."
  fi
  note "adb is root: $SH_OUT"

  wait_for_boot
  note "sys.boot_completed=1"

  if sh_run 'getprop ro.product.model'; then
    DEV_MODEL="$(printf '%s' "$SH_OUT" | tr -d '\r' | sed -n '1p')"
  fi
  [ -n "$DEV_MODEL" ] || DEV_MODEL="unknown"
  say "device model: $DEV_MODEL"

  if ! sh_run "[ -x $BB ]"; then
    die "the June busybox is missing: $BB" \
      "The stock June system ships /system/bin/busybox and the boot scripts use" \
      "it. Without it this script cannot verify what it wrote. Re-run the USB" \
      "installer to repair /system."
  fi
  if ! sh_run "[ -x $JUNE_LOCAL ]"; then
    die "this oven does not have the June Local server: $JUNE_LOCAL" \
      "The custom payload is useless without the boot image's /system/xbin/june-local." \
      "Run the USB/ISO installer first; this ADB path only re-applies the payload."
  fi
  if ! sh_run "$BB grep -q apply_staged_apk $REAPER"; then
    die "the running system does not have the June Local boot script: $REAPER" \
      "The patched june_reaper.sh is what mounts the collector read-write and" \
      "applies staged APKs at boot. A stock reaper would ignore the payload." \
      "Run the USB/ISO installer first; this ADB path only re-applies the payload."
  fi
  note "June Local server and patched june_reaper.sh are present"

  if ! sh_run "[ -d $DATA_DIR ]"; then
    die "$DATA_DIR is missing on the oven." \
      "The June Local install creates it. Run the USB/ISO installer once, then" \
      "use this script for payload-only redeploys."
  fi

  if sh_run 'getprop ro.june_encfs'; then
    out="$(printf '%s' "$SH_OUT" | tr -d ' \t')"
    if [ "$out" != "1" ]; then
      warn "ro.june_encfs is '$out' (expected 1): the previous boot may not have" \
        "completed the collector mount. The next boot retries it, so this deploy" \
        "will still apply - but check /data/june/logs if the status page is odd."
    fi
  fi

  if sh_run 'cat /system/etc/hosts'; then
    if ! printf '%s\n' "$SH_OUT" | grep -q 'api\.junelife\.com'; then
      warn "/system/etc/hosts has no api.junelife.com override; the June apps may" \
        "keep trying the real cloud instead of june-local."
    fi
    if ! printf '%s\n' "$SH_OUT" | grep -q 'messaging\.junelife\.com'; then
      warn "/system/etc/hosts has no messaging.junelife.com override."
    fi
  fi
}

# ---------------------------------------------------------------------------
# Collect the oven's current state (read-only)
# ---------------------------------------------------------------------------
collect_state() {
  local h d av need

  if remote_exists "$INSTALL_JSON"; then
    if "${ADB[@]}" pull "$INSTALL_JSON" "$TMP_DIR/existing-install.json" >/dev/null 2>&1; then
      EXISTING_JSON="$TMP_DIR/existing-install.json"
      note "existing install.json pulled for merge"
    else
      warn "could not pull $INSTALL_JSON; component provenance will be inferred from the device"
    fi
  else
    note "no existing install.json (first payload deploy over ADB)"
  fi

  if remote_exists "$HOSTNAME_FILE"; then
    if sh_run "cat $HOSTNAME_FILE"; then
      DEV_HOST="$(printf '%s' "$SH_OUT" | tr -d ' \t\n')"
      DEV_HOST="${DEV_HOST%.local}"
    fi
  fi
  if [ -n "$OVEN_HOST" ]; then
    if [ "$OVEN_HOST" != "$DEV_HOST" ]; then
      HOSTNAME_CHANGED=1
    fi
  else
    OVEN_HOST="${DEV_HOST:-june}"
    normalize_host "$OVEN_HOST"
    OVEN_HOST="$NORMALIZED_HOST"
  fi
  say "hostname: $OVEN_HOST (device has: ${DEV_HOST:-none})"

  local prop cand
  for prop in dhcp.wlan0.ipaddress dhcp.eth0.ipaddress dhcp.wlan1.ipaddress; do
    if [ -z "$DEV_IP" ]; then
      if sh_run "getprop $prop"; then
        cand="$(printf '%s' "$SH_OUT" | tr -d ' \t\r\n')"
        case "$cand" in
          0.0.0.0|'') ;;
          [0-9]*.[0-9]*.[0-9]*.[0-9]*) DEV_IP="$cand" ;;
        esac
      fi
    fi
  done
  if [ -n "$DEV_IP" ]; then
    say "oven IP now: $DEV_IP (recorded install_ip: $INSTALL_IP)"
    if [ "$DEV_IP" != "$INSTALL_IP" ]; then
      warn "the oven reports $DEV_IP but --install-ip is $INSTALL_IP:" \
        "/local will show the amber 'Oven IP changed since install' problem," \
        "and clients using the IP need certificates issued for $DEV_IP."
    fi
  fi

  if remote_exists "$COMPANIONS_JSON"; then
    COMPANIONS_BEFORE="$(dev_sha "$COMPANIONS_JSON")"
    note "companion registry present; sha256 $COMPANIONS_BEFORE (will not be touched)"
  else
    warn "$COMPANIONS_JSON is missing; pairing state may be empty on this oven."
  fi

  BACKUP_DIR="$DATA_DIR/backups/adb-deploy-$(date -u +%Y%m%dT%H%M%SZ)"
  say "backups will go to: $BACKUP_DIR"

  C_JUNE_LOCAL="$(json_comp "$EXISTING_JSON" "june-local")"
  C_CAMERAD="$(json_comp "$EXISTING_JSON" "june-camerad")"
  C_OVENLIGHT="$(json_comp "$EXISTING_JSON" "OvenLight")"
  C_CHEF="$(json_comp "$EXISTING_JSON" "Chef")"
  C_ANALYTICS="$(json_comp "$EXISTING_JSON" "Analytics")"

  if [ -z "$C_JUNE_LOCAL" ]; then
    C_JUNE_LOCAL="$(dev_sha "$JUNE_LOCAL")"
    if [ -n "$C_JUNE_LOCAL" ]; then
      note "recorded installed june-local hash from the device"
    fi
  fi
  if [ -z "$C_CAMERAD" ]; then
    C_CAMERAD="$(dev_sha "/system/xbin/june-camerad")"
    if [ -n "$C_CAMERAD" ]; then
      note "recorded installed june-camerad hash from the device"
    fi
  fi
  if [ -z "$C_OVENLIGHT" ]; then
    C_OVENLIGHT="$(dev_sha "/system/app/JuneLight/JuneLight.apk")"
  fi
  if [ -z "$C_CHEF" ]; then
    if remote_exists "$STAGE_DIR/chef_cookmodes.apk"; then
      C_CHEF="$(dev_sha "$STAGE_DIR/chef_cookmodes.apk")"
      if [ -n "$C_CHEF" ]; then
        note "existing staged Chef patch is left in place and will be applied at boot"
      fi
    else
      C_CHEF="$(dev_sha "/system/priv-app/Chef/Chef.apk")"
    fi
  fi
  if [ -z "$C_ANALYTICS" ]; then
    C_ANALYTICS="$(dev_sha "/system/app/Analytics/Analytics.apk")"
  fi

  av="$(df_avail_kb /data)"
  case "$av" in
    ''|*[!0-9]*) av="" ;;
  esac
  need=$(( (JCM_BYTES + REMOTES_BYTES + MEDIA_BYTES + 1023) / 1024 * 2 + DISK_MARGIN_KB ))
  if [ -n "$av" ] && [ "$av" -lt "$need" ]; then
    die "/data does not have enough free space for the payload." \
      "need about $((need / 1024)) MB (APKs plus margin), available $((av / 1024)) MB." \
      "Free space on /data and retry."
  fi
  say "/data free: ${av:-unknown} KiB (need about $((need / 1024)) MB incl. margin)"

  av="$(df_avail_kb /system)"
  case "$av" in
    ''|*[!0-9]*) av="" ;;
  esac
  if [ -n "$av" ] && [ "$av" -lt 8192 ]; then
    die "/system does not have enough free space for the certificates (need 8 MB)." \
      "Free space on /system and retry; available $((av / 1024)) MB."
  fi
  say "/system free: ${av:-unknown} KiB"
}

# check_hostname_san: re-check the hostname once the device's own name is known
# (or when --hostname was changed). /local and mDNS advertise this name, so the
# leaf must carry it as a DNS SAN.
check_hostname_san() {
  local cand
  HOST_IN_SAN=0
  for cand in "$OVEN_HOST" "$OVEN_HOST.local"; do
    if [ -n "$cand" ]; then
      if printf '%s\n' "$SAN_ITEMS" | grep -qx "DNS:$cand"; then
        HOST_IN_SAN=1
      fi
    fi
  done
  if [ "$HOST_IN_SAN" -ne 1 ]; then
    if [ "$ALLOW_CERT_WARNINGS" -ne 1 ]; then
      die "the leaf certificate does not cover hostname $OVEN_HOST." \
        "SANs: $SAN_ITEMS" \
        "Pass --hostname matching a DNS SAN, re-issue the certs with" \
        "JUNE_HOSTNAME=$OVEN_HOST, or re-run with --allow-cert-warnings."
    fi
    warn "the leaf certificate does not cover hostname $OVEN_HOST (accepted)."
  fi
}

# ---------------------------------------------------------------------------
# Per-oven June account identity (token + AccountManager seed)
# ---------------------------------------------------------------------------
# Design: docs/identity-generation.md.  /system/etc/june/identity holds the
# per-oven token and the seed DB, which survive a factory reset; the patched
# june_reaper.sh copies the seed into /data/system/users/0/accounts.db before
# Android starts when the June account row is missing.  deploy_onoven.sh does
# this offline in UMS mode; this is the same flow over ADB, additive to it.

identity_token_valid() {
  [[ "$1" =~ ^v2:[A-Za-z0-9_-]{28}$ ]]
}

find_python() {
  local cand
  PYTHON_BIN=""
  if [ -n "$PYTHON" ]; then
    if command -v "$PYTHON" >/dev/null 2>&1; then
      PYTHON_BIN="$PYTHON"
      return 0
    fi
    return 1
  fi
  for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1; then
      PYTHON_BIN="$cand"
      return 0
    fi
  done
  return 1
}

# find_identity_asset NAME: generator/template shipped next to the payload, the
# script, the repo's live-ISO assets, or the live ISO payload directory.
find_identity_asset() {
  local name="$1" cand
  for cand in \
    "$APK_DIR/$name" \
    "$SCRIPT_DIR/$name" \
    "$SCRIPT_DIR/../installer/liveiso/assets/$name" \
    "/opt/june-installer/$name"; do
    if [ -n "$cand" ] && [ -f "$cand" ]; then
      printf '%s' "$cand"
      return 0
    fi
  done
  printf ''
}

# collect_identity_state: read-only probe of the oven's existing identity.
collect_identity_state() {
  local sz
  EXISTING_ID_TOKEN=""
  SYS_IDENTITY_PRESENT=0
  IDENTITY_SEED_PRESENT=0
  DATA_IDENTITY_EXISTS=0
  DATA_ID_TOKEN=""
  DATA_ID_ALIGNED=0
  DATA_ID_REWRITTEN=0
  ACCOUNT_PRESENT="false"
  JCM_STAGED=0

  if remote_exists "$ID_TOKEN"; then
    if sh_run "cat $ID_TOKEN"; then
      EXISTING_ID_TOKEN="$(printf '%s' "$SH_OUT" | tr -d ' \t\r\n')"
    fi
  fi
  if identity_token_valid "$EXISTING_ID_TOKEN"; then
    SYS_IDENTITY_PRESENT=1
  fi
  if remote_exists "$ID_SEED"; then
    sz="$(remote_size "$ID_SEED")"
    if [ -n "$sz" ] && [ "$sz" -gt 0 ]; then
      IDENTITY_SEED_PRESENT=1
    fi
  fi
  if remote_exists "$DATA_ID_JSON"; then
    DATA_IDENTITY_EXISTS=1
    if sh_run "cat $DATA_ID_JSON"; then
      # Keep only the account token; full identity.json is never echoed.
      DATA_ID_TOKEN="$(printf '%s' "$SH_OUT" | tr -d '\n' \
        | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    fi
  fi
  if remote_exists "$ACCOUNTS_DB"; then
    if sh_run "$BB grep -aqF com.junelife.user $ACCOUNTS_DB"; then
      ACCOUNT_PRESENT="true"
    fi
  fi
  if remote_exists "$STAGE_DIR/jcm_nopin.apk"; then
    JCM_STAGED=1
  fi
  if remote_exists "$JCM_STAGE"; then
    JCM_STAGED=1
  fi
  note "identity now: token=${SYS_IDENTITY_PRESENT} seed=${IDENTITY_SEED_PRESENT} data-record=${DATA_IDENTITY_EXISTS} june-account=${ACCOUNT_PRESENT} jcm-staged=${JCM_STAGED}"
}

# prepare_identity_assets: decide preserve/generate, mint the token and build the
# seed when needed, and write the identity record locally.  Runs before the
# confirmation and before any oven write, so the prerequisites fail closed.
prepare_identity_assets() {
  local gen tmpl out token
  IDENTITY_MODE=""
  IDENTITY_TOKEN=""
  IDENTITY_TOKEN_SHA=""
  IDENTITY_SEED_SOURCE="unavailable"
  IDENTITY_SEED_LOCAL=""
  IDENTITY_JSON_LOCAL=""
  IDENTITY_TOKEN_FILE_LOCAL=""

  if [ "$SYS_IDENTITY_PRESENT" -eq 1 ] && [ "$IDENTITY_SEED_PRESENT" -eq 1 ]; then
    IDENTITY_MODE="preserve"
    IDENTITY_TOKEN="$EXISTING_ID_TOKEN"
    IDENTITY_SEED_SOURCE="preserved"
    note "identity: preserving the /system token + seed already on the oven"
  else
    IDENTITY_MODE="generate"
    gen="$IDENTITY_GEN"
    tmpl="$IDENTITY_TEMPLATE"
    if [ -z "$gen" ]; then
      gen="$(find_identity_asset generate_identity.py)"
    fi
    if [ -z "$tmpl" ]; then
      tmpl="$(find_identity_asset accounts_template.db)"
    fi
    if [ -z "$gen" ] || [ ! -f "$gen" ] || [ -z "$tmpl" ] || [ ! -f "$tmpl" ]; then
      if [ "$ALLOW_IDENTITY_MISSING" -eq 1 ]; then
        IDENTITY_MODE="skip"
        warn "identity: no /system seed and no generator/template to build one;"
        warn "identity: continuing only because --allow-identity-missing is set."
        return 0
      fi
      die "the oven has no usable June account identity and the installer assets to mint one are missing." \
        "Checked generator: ${gen:-<not found>}" \
        "Checked template : ${tmpl:-<not found>}" \
        "Without /system/etc/june/identity/{token,accounts_seed.db} the patched" \
        "june_reaper.sh cannot restore the June account after a factory reset," \
        "and /local/status reports the red 'Oven identity is missing' problem." \
        "Fix one of:" \
        "  1. Point at the installer payload assets and re-run:" \
        "       --identity-gen <payload>/generate_identity.py" \
        "       --identity-template <payload>/accounts_template.db" \
        "     (live ISO payload: /opt/june-installer/; this repo:" \
        "      installer/installer/liveiso/assets/). python3 must be on PATH." \
        "  2. Run the USB/ISO installer once (it pre-seeds /system/etc/june/identity" \
        "     in both system slots), then re-run this ADB deploy." \
        "  3. Re-run with --allow-identity-missing to deploy certs/APKs only" \
        "     (not recommended: the oven stays broken after a factory reset)." \
        "Nothing on the oven was changed."
    fi
    if ! find_python; then
      if [ "$ALLOW_IDENTITY_MISSING" -eq 1 ]; then
        IDENTITY_MODE="skip"
        warn "identity: python3 not found to build the account seed; continuing only"
        warn "identity: because --allow-identity-missing is set."
        return 0
      fi
      die "python3 is required to mint the June account seed and was not found." \
        "Install python3, or run the USB/ISO installer once to pre-seed" \
        "/system/etc/june/identity in both system slots, or re-run with" \
        "--allow-identity-missing (not recommended)." \
        "Nothing on the oven was changed."
    fi
    token=""
    if [ "$SYS_IDENTITY_PRESENT" -eq 1 ]; then
      token="$EXISTING_ID_TOKEN"
      note "identity: reusing the valid /system token; rebuilding accounts_seed.db"
    fi
    if [ -z "$token" ]; then
      token="$("$PYTHON_BIN" "$gen" mint-token 2>/dev/null)" || token=""
      token="$(printf '%s' "$token" | tr -d ' \t\r\n')"
      if ! identity_token_valid "$token"; then
        die "identity: could not mint a v2: token with $gen" \
          "The generator did not print a token in the expected v2: + 28 URL-safe" \
          "base64 characters form. Nothing on the oven was changed."
      fi
      note "identity: minted a fresh per-oven v2: token"
    fi
    IDENTITY_TOKEN="$token"
    IDENTITY_SEED_LOCAL="$TMP_DIR/accounts_seed.db"
    if ! "$PYTHON_BIN" "$gen" make-seed "$tmpl" "$IDENTITY_SEED_LOCAL" "$token" >/dev/null 2>&1; then
      die "identity: could not build accounts_seed.db from $tmpl" \
        "Nothing on the oven was changed."
    fi
    if [ "$(head -c 15 "$IDENTITY_SEED_LOCAL")" != "SQLite format 3" ]; then
      die "identity: generated account seed is not a SQLite database" \
        "File: $IDENTITY_SEED_LOCAL  Template: $tmpl" \
        "Nothing on the oven was changed."
    fi
    if ! "$PYTHON_BIN" "$gen" check "$IDENTITY_SEED_LOCAL" >/dev/null 2>&1; then
      warn "identity: the generator's integrity check failed for the new seed"
    fi
    IDENTITY_SEED_SOURCE="generated"
    note "identity: generated accounts_seed.db from ${tmpl##*/}"
  fi

  IDENTITY_TOKEN_SHA="$(printf '%s' "$IDENTITY_TOKEN" | "${SHA_CMD[@]}" | awk '{print substr($1,1,8)}')"
  if [ -z "$IDENTITY_TOKEN_SHA" ]; then
    die "identity: could not hash the identity token with ${SHA_CMD[*]}"
  fi
  IDENTITY_TOKEN_FILE_LOCAL="$TMP_DIR/identity_token"
  printf '%s\n' "$IDENTITY_TOKEN" > "$IDENTITY_TOKEN_FILE_LOCAL"
  DATA_ID_ALIGNED=0
  if [ "$DATA_IDENTITY_EXISTS" -eq 1 ] && identity_token_valid "$DATA_ID_TOKEN" \
     && [ "$DATA_ID_TOKEN" = "$IDENTITY_TOKEN" ]; then
    DATA_ID_ALIGNED=1
  fi
  write_identity_json_local
  note "identity: plan=$IDENTITY_MODE seed_source=$IDENTITY_SEED_SOURCE token_sha256_prefix=$IDENTITY_TOKEN_SHA"
}

# write_identity_json_local: the identity record for /system and /data
# (docs/identity-generation.md 4.3), same shape deploy_onoven.sh writes.
write_identity_json_local() {
  local out
  out="$TMP_DIR/identity.json"
  cat > "$out" <<JSON
{
  "version": 1,
  "role": "oven",
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "generated_by": "june-local-adb-deploy/$INSTALLER_VERSION",
  "endpoint": { "api": "https://$INSTALL_IP", "messaging": "wss://$INSTALL_IP" },
  "account": {
    "name": "June Oven",
    "type": "com.junelife.user",
    "token_type": "Full access",
    "refresh_token_type": "Refresh access",
    "token": "$IDENTITY_TOKEN"
  },
  "oven": {
    "device_id": null,
    "model": "meerkat",
    "serial": null
  },
  "notes": "token minted locally at install time; the local relay accepts any bearer token; the Ed25519 signing key is in the ATECC508A and survives a reset"
}
JSON
  chmod 0644 "$out"
  IDENTITY_JSON_LOCAL="$out"
}

# push_identity: write the identity to /system (read-write by now), the /data
# record when absent, and the token fallback property when a JCM patch is staged.
push_identity() {
  if [ "$IDENTITY_MODE" = "skip" ]; then
    warn "identity: not seeded (--allow-identity-missing); /local will keep"
    warn "identity: reporting identity-missing until a seed is installed."
    return 0
  fi
  if ! sh_run "$BB mkdir -p $ID_DIR"; then
    die "could not create $ID_DIR on the oven."
  fi
  if [ "$IDENTITY_MODE" = "generate" ]; then
    push_file "$IDENTITY_TOKEN_FILE_LOCAL" "$ID_TOKEN" "0644"
    push_file "$IDENTITY_SEED_LOCAL" "$ID_SEED" "0644"
  else
    note "identity: left the existing $ID_TOKEN and $ID_SEED in place"
  fi
  push_file "$IDENTITY_JSON_LOCAL" "$ID_JSON" "0644"

  DATA_ID_REWRITTEN=0
  if [ "$DATA_IDENTITY_EXISTS" -eq 1 ] && [ "$DATA_ID_ALIGNED" -eq 1 ]; then
    note "identity: preserving the existing runtime record $DATA_ID_JSON (same token)"
  elif [ "$DATA_IDENTITY_EXISTS" -eq 1 ]; then
    note "identity: replacing the runtime record $DATA_ID_JSON (its token differs from the /system seed; backup: data-identity.json)"
    push_file "$IDENTITY_JSON_LOCAL" "$DATA_ID_JSON" "0600"
    DATA_ID_REWRITTEN=1
  else
    push_file "$IDENTITY_JSON_LOCAL" "$DATA_ID_JSON" "0600"
    DATA_ID_REWRITTEN=1
  fi

  JCM_PROP_SET=0
  if [ "$JCM_STAGED" -eq 1 ] || remote_exists "$JCM_STAGE"; then
    if sh_run "/system/bin/setprop $JUNE_TOKEN_PROP $IDENTITY_TOKEN"; then
      JCM_PROP_SET=1
      note "identity: set $JUNE_TOKEN_PROP for the staged JCM token fallback"
    else
      warn "identity: could not set $JUNE_TOKEN_PROP; june_reaper sets it at boot"
    fi
  else
    note "identity: no JCM patch staged; leaving $JUNE_TOKEN_PROP untouched"
  fi
}

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
confirm() {
  local reboot_note="and reboot"
  if [ "$DO_REBOOT" -ne 1 ]; then
    reboot_note="no reboot (--no-reboot)"
  fi
  cat <<EOF

== Plan ==
  target device   : ${SERIAL} (${DEV_MODEL})
  oven IP now     : ${DEV_IP:-unknown}
  install_ip      : ${INSTALL_IP}
  hostname        : ${OVEN_HOST} (update /system/etc/june_hostname: ${HOSTNAME_CHANGED})
  certificates    : ${CERT_DIR} (leaf + per-home CA, CA store name ${CA_HASH}.0)
  payload APKs    : ${APK_DIR}
  identity        : ${IDENTITY_MODE:-none} (seed source ${IDENTITY_SEED_SOURCE}, token sha256 prefix ${IDENTITY_TOKEN_SHA:-none})
  June account now: ${ACCOUNT_PRESENT} (installed by june_reaper before Android on the next boot when false)
  backups         : ${BACKUP_DIR}
  reboot after    : ${reboot_note}

  It will: back up the current files, remount /system read-write, replace the
  certificate/key/CA (and install the CA into the system trust store), remove
  stale /system staged patches, seed the per-oven June account identity in
  /system (token + AccountManager seed) when it is missing, stage the three
  no-pin APKs in /data/june, rewrite /data/june/install.json, remount /system
  read-only, sync, ${reboot_note}.

  It will NOT: flash a boot image, use RCM, or factory-reset the oven.

EOF
  if [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    die "refusing to modify the oven without confirmation." \
      "stdin is not a terminal; re-run with --yes when you have checked the plan above."
  fi
  local reply=""
  printf 'Type YES to continue: '
  read -r reply || reply=""
  if [ "$reply" != "YES" ]; then
    die "aborted at the confirmation prompt; nothing on the oven was changed."
  fi
}

# ---------------------------------------------------------------------------
# Writes
# ---------------------------------------------------------------------------
make_backup() {
  local p
  if [ -z "$BACKUP_DIR" ]; then
    BACKUP_DIR="$DATA_DIR/backups/adb-deploy-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  if ! sh_run "$BB mkdir -p $DATA_DIR $BACKUP_DIR"; then
    die "could not create the backup directory: $BACKUP_DIR" \
      "Check that /data is mounted and writable."
  fi
  for p in "$LEAF_CRT" "$LEAF_KEY" "$CA_CRT" "$CACERTS_DIR/$CA_HASH.0" "$HOSTNAME_FILE" "$INSTALL_JSON" \
           "$ID_TOKEN" "$ID_SEED" "$ID_JSON"; do
    backup_one "$p"
  done
  # /data/june/identity.json has the same basename as the /system record; copy it
  # under a distinct name so the backup is unambiguous.
  if remote_exists "$DATA_ID_JSON"; then
    if ! sh_run "$BB cp -p $DATA_ID_JSON $BACKUP_DIR/data-identity.json"; then
      die "could not back up $DATA_ID_JSON to $BACKUP_DIR/data-identity.json"
    fi
    note "backed up $DATA_ID_JSON (as data-identity.json)"
  fi
  # STALE_STAGES is a space-separated list; splitting it is intended here.
  for p in $STALE_STAGES; do
    backup_one "$p"
  done
  note "backups: $BACKUP_DIR"
}

backup_one() {
  local p="$1"
  if remote_exists "$p"; then
    if ! sh_run "$BB cp -p $p $BACKUP_DIR/${p##*/}"; then
      die "could not back up $p to $BACKUP_DIR/"
    fi
    note "backed up $p"
  fi
}

remount_system_rw() {
  local src=""
  if ! sh_run 'mount -o rw,remount /system'; then
    warn "mount -o rw,remount /system failed; trying busybox mount"
  fi
  if ! system_is_rw; then
    sh_run "$BB mount -o rw,remount /system" || true
  fi
  if ! system_is_rw; then
    if sh_run 'cat /proc/mounts'; then
      src="$(printf '%s\n' "$SH_OUT" | awk '$2=="/system" {print $1; exit}')"
    fi
    if [ -n "$src" ]; then
      sh_run "$BB mount -o rw,remount -t ext4 $src /system" || true
    fi
  fi
  if ! system_is_rw; then
    die "could not remount /system read-write." \
      "Tried: mount -o rw,remount /system, busybox mount -o rw,remount /system," \
      "and an explicit ext4 remount of the /system block device." \
      "A stock or verity-protected system is not writable this way: install the" \
      "June Local boot image + patched scripts with the USB installer first." \
      "Only the backup directory under /data was added; no payload was written."
  fi
  if ! sh_run 'echo june-adb-probe > /system/etc/.june_adb_write_probe'; then
    die "/system reports read-write but writes still fail." \
      "The filesystem is probably protected (dm-verity / read-only remount)." \
      "Nothing on the oven was changed."
  fi
  sh_run 'rm -f /system/etc/.june_adb_write_probe' || warn "could not remove the /system write probe"
  SYSTEM_RW=1
  note "/system remounted read-write"
}

remove_stale_stage() {
  local p
  for p in $STALE_STAGES; do
    if remote_exists "$p"; then
      if ! sh_run "$BB rm -f $p"; then
        die "could not remove the stale persistent patch: $p" \
          "june_reaper would prefer it over the /data stage and silently keep" \
          "an older patch. The file was backed up to $BACKUP_DIR/."
      fi
      note "removed stale persistent patch $p (backed up)"
    fi
  done
}

push_file() {
  local src="$1" dst="$2" mode="$3" want got lsha dsize
  if ! "${ADB[@]}" push "$src" "$dst" >/dev/null 2>&1; then
    die "adb push failed: $src -> $dst" \
      "Backups are in $BACKUP_DIR/; re-run after fixing the transport error."
  fi
  if ! sh_run "$BB chmod $mode $dst"; then
    die "could not chmod $mode $dst"
  fi
  sh_run "$BB chown 0:0 $dst" || warn "could not chown 0:0 $dst"
  want="${mode#0}"
  got="$(dev_mode "$dst")"
  got="${got#0}"
  if [ -n "$got" ] && [ "$got" != "$want" ]; then
    die "wrong mode on $dst: $got, expected $want"
  fi
  lsha="$(host_sha "$src")"
  dsize="$(remote_size "$dst")"
  if [ -n "$lsha" ] && [ -n "$dsize" ] && [ "$lsha" = "$(dev_sha "$dst")" ]; then
    note "pushed $dst ($mode, sha256 ${lsha:0:12})"
    return 0
  fi
  if [ -n "$dsize" ] && [ "$dsize" = "$(wc -c < "$src" | tr -d ' ')" ]; then
    warn "sha256 unavailable for $dst; size matches ($dsize bytes)"
    return 0
  fi
  die "the pushed file does not match its source: $dst" \
    "Local sha256: $lsha" \
    "Backups are in $BACKUP_DIR/."
}

build_install_json() {
  local out="$TMP_DIR/install.json" date_utc
  date_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat > "$out" <<JSON
{
  "mode": "custom",
  "date": "$date_utc",
  "installer_version": "$INSTALLER_VERSION",
  "build_id": "$BUILD_ID",
  "persistence": "off",
  "ca_mode": "per-home",
  "hostname": "$OVEN_HOST",
  "install_ip": "$INSTALL_IP",
  "identity": {
    "account_present": $ACCOUNT_PRESENT,
    "seed_source": "$IDENTITY_SEED_SOURCE",
    "token_sha256_prefix": "$IDENTITY_TOKEN_SHA"
  },
  "components": {
    "june-local": "$C_JUNE_LOCAL",
    "june-camerad": "$C_CAMERAD",
    "OvenLight": "$C_OVENLIGHT",
    "Chef": "$C_CHEF",
    "JuneCloudMessaging": "$JCM_SHA",
    "Remotes": "$REMOTES_SHA",
    "MediaCapturer": "$MEDIA_SHA",
    "Analytics": "$C_ANALYTICS"
  }
}
JSON
  INSTALL_JSON_LOCAL="$out"
  if have python3; then
    if ! python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$out" >/dev/null 2>&1; then
      die "generated install.json is not valid JSON"
    fi
  fi
}

push_payload() {
  local h
  if ! sh_run "$BB mkdir -p $DATA_DIR"; then
    die "could not create $DATA_DIR on the oven."
  fi

  push_file "$CHAIN_FILE" "$LEAF_CRT" "0644"
  push_file "$CERT_DIR/leaf.key" "$LEAF_KEY" "0600"
  push_file "$CA_PEM" "$CA_CRT" "0644"

  if ! sh_run "[ -d $CACERTS_DIR ]"; then
    die "the oven's system trust store is missing: $CACERTS_DIR" \
      "A stock Android system always has it; this oven's /system looks damaged."
  fi
  push_file "$CA_PEM" "$CACERTS_DIR/$CA_HASH.0" "0644"

  if [ "$HOSTNAME_CHANGED" -eq 1 ]; then
    HOSTNAME_TMP="$TMP_DIR/june_hostname"
    printf '%s\n' "$OVEN_HOST" > "$HOSTNAME_TMP"
    push_file "$HOSTNAME_TMP" "$HOSTNAME_FILE" "0644"
  fi

  push_file "$APK_DIR/$JCM_APK_NAME" "$JCM_STAGE" "0644"
  push_file "$APK_DIR/$REMOTES_APK_NAME" "$REMOTES_STAGE" "0644"
  push_file "$APK_DIR/$MEDIA_APK_NAME" "$MEDIA_STAGE" "0644"

  push_identity

  build_install_json
  push_file "$INSTALL_JSON_LOCAL" "$INSTALL_JSON" "0644"
}

verify_file() {
  local p="$1" want="$2" label="$3" got
  got="$(dev_sha "$p")"
  if [ -z "$got" ]; then
    VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
    warn "could not verify $label ($p): no sha256 from the oven"
    return 0
  fi
  if [ "$got" != "$want" ]; then
    VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
    warn "MISMATCH $label ($p): oven has $got"
    warn "                            expected $want"
    return 0
  fi
  note "verified $label $p"
}

verify_payload() {
  CHAIN_SHA="$(host_sha "$CHAIN_FILE")"
  KEY_SHA="$(host_sha "$CERT_DIR/leaf.key")"
  CA_SHA="$(host_sha "$CA_PEM")"
  INSTALL_SHA="$(host_sha "$INSTALL_JSON_LOCAL")"

  verify_file "$LEAF_CRT" "$CHAIN_SHA" "leaf chain"
  verify_file "$LEAF_KEY" "$KEY_SHA" "leaf key"
  verify_file "$CA_CRT" "$CA_SHA" "per-home CA"
  verify_file "$CACERTS_DIR/$CA_HASH.0" "$CA_SHA" "system-store CA"
  if [ "$HOSTNAME_CHANGED" -eq 1 ]; then
    verify_file "$HOSTNAME_FILE" "$(host_sha "$HOSTNAME_TMP")" "hostname"
  fi
  verify_file "$JCM_STAGE" "$JCM_SHA" "JuneCloudMessaging patch"
  verify_file "$REMOTES_STAGE" "$REMOTES_SHA" "Remotes patch"
  verify_file "$MEDIA_STAGE" "$MEDIA_SHA" "MediaCapturer patch"
  verify_file "$INSTALL_JSON" "$INSTALL_SHA" "install.json"

  if [ "$IDENTITY_MODE" = "generate" ]; then
    verify_file "$ID_TOKEN" "$(host_sha "$IDENTITY_TOKEN_FILE_LOCAL")" "identity token"
    verify_file "$ID_SEED" "$(host_sha "$IDENTITY_SEED_LOCAL")" "identity account seed"
  elif [ "$IDENTITY_MODE" = "preserve" ]; then
    note "identity: kept the existing /system token (validated at probe) and seed"
  fi
  if [ "$IDENTITY_MODE" = "generate" ] || [ "$IDENTITY_MODE" = "preserve" ]; then
    verify_file "$ID_JSON" "$(host_sha "$IDENTITY_JSON_LOCAL")" "system identity record"
    if [ "$DATA_ID_REWRITTEN" -eq 1 ]; then
      verify_file "$DATA_ID_JSON" "$(host_sha "$IDENTITY_JSON_LOCAL")" "runtime identity record"
      local idm
      idm="$(dev_mode "$DATA_ID_JSON")"
      idm="${idm#0}"
      if [ "$idm" != "600" ]; then
        VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
        warn "runtime identity record mode is $idm, expected 600"
      fi
    fi
  fi

  local m
  m="$(dev_mode "$LEAF_KEY")"; m="${m#0}"
  if [ "$m" != "600" ]; then
    VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
    warn "leaf key mode is $m, expected 600"
  fi
  m="$(dev_mode "$LEAF_CRT")"; m="${m#0}"
  if [ "$m" != "644" ]; then
    VERIFY_ERRORS=$((VERIFY_ERRORS + 1))
    warn "leaf chain mode is $m, expected 644"
  fi

  if [ "$VERIFY_ERRORS" -ne 0 ]; then
    die "post-push verification failed ($VERIFY_ERRORS problem(s))." \
      "The oven's current state is a mix of old and new files." \
      "Restore from $BACKUP_DIR/ with: adb shell $BB cp -p $BACKUP_DIR/<name> <path>" \
      "(remount /system read-write first), then re-run."
  fi
}

finish() {
  if ! sh_run 'sync'; then
    warn "sync on the oven reported an error"
  fi
  if sh_run 'mount -o ro,remount /system'; then
    SYSTEM_RW=0
    note "/system remounted read-only"
  else
    warn "could not remount /system read-only; it will be remounted at the next boot."
  fi

  if [ -n "$COMPANIONS_BEFORE" ]; then
    COMPANIONS_AFTER="$(dev_sha "$COMPANIONS_JSON")"
    if [ -n "$COMPANIONS_AFTER" ] && [ "$COMPANIONS_AFTER" != "$COMPANIONS_BEFORE" ]; then
      warn "companions_state.json changed unexpectedly ($COMPANIONS_AFTER != $COMPANIONS_BEFORE)"
    else
      note "companion registry unchanged (sha256 ${COMPANIONS_BEFORE:0:12})"
    fi
  fi

  if [ "$DO_REBOOT" -eq 1 ]; then
    say "rebooting so the June Local june_reaper.sh applies the staged patches at boot"
    if ! "${ADB[@]}" reboot; then
      die "adb reboot failed." \
        "Power-cycle the oven by hand (the payload is staged and safe)."
    fi
    note "reboot issued"
  else
    note "--no-reboot: payload staged on the oven; reboot it (adb reboot or"
    note "power-cycle) to let june_reaper apply the patches during the collector mount."
  fi
}

# ---------------------------------------------------------------------------
# Final report: /local verification fields, caveats, restore
# ---------------------------------------------------------------------------
print_verification() {
  cat <<'TXT'

== What to verify on the oven status page ==

  Browser:  https://<oven-ip>/local      (http://<oven-ip>/local also answers)
  JSON:     https://<oven-ip>/local/status     (curl -k)

  Expect these fields after the reboot has applied the payload:
TXT
  printf '  This oven: https://%s/local\n' "$INSTALL_IP"
  printf '    install.mode                 = custom\n'
  printf '    install.ca_mode              = per-home\n'
  printf '    install.install_ip           = %s\n' "$INSTALL_IP"
  printf '    install.hostname             = %s\n' "$OVEN_HOST"
  printf '    install.installer_version    = %s\n' "$INSTALLER_VERSION"
  printf '    install.build_id             = %s\n' "$BUILD_ID"
  printf '    install.persistence          = off   (payload staged in /data)\n'
  printf '    cert.has_ip_san              = true\n'
  printf '    cert.ca_in_system_store      = true\n'
  printf '    cert.leaf_key_present        = true\n'
  printf '    cert.san_covers_current_ip   = true  (unless the oven IP changed)\n'
  cat <<'TXT'

  Component checks (install.components[] -> ok should be true):
TXT
  printf '    june-local         %s\n' "$C_JUNE_LOCAL"
  printf '    june-camerad       %s\n' "$C_CAMERAD"
  printf '    OvenLight          %s\n' "$C_OVENLIGHT"
  printf '    Chef               %s\n' "$C_CHEF"
  printf '    JuneCloudMessaging %s\n' "$JCM_SHA"
  printf '    Remotes            %s\n' "$REMOTES_SHA"
  printf '    MediaCapturer      %s\n' "$MEDIA_SHA"
  cat <<'TXT'

  Per-oven June account identity (install.json identity block, and the runtime
  probe /local/status reports):
TXT
  printf '    install.identity.seed_source        = %s\n' "$IDENTITY_SEED_SOURCE"
  printf '    install.identity.token_sha256_pref  = %s\n' "${IDENTITY_TOKEN_SHA:-none}"
  printf '    identity.account_present            = %s   (now; see note below)\n' "$ACCOUNT_PRESENT"
  local tok_src="none"
  if [ "$DATA_IDENTITY_EXISTS" -eq 1 ] && [ "$DATA_ID_ALIGNED" -eq 1 ]; then
    tok_src="identity.json (existing, preserved)"
  elif [ "$DATA_ID_REWRITTEN" -eq 1 ]; then
    tok_src="identity.json (rewritten to the /system seed token)"
  elif [ "$SYS_IDENTITY_PRESENT" -eq 1 ]; then
    tok_src="system-token"
  fi
  printf '    identity.token_source               = %s\n' "$tok_src"
  cat <<'TXT'
    The patched june_reaper.sh installs /system/etc/june/identity/accounts_seed.db
    into /data/system/users/0/accounts.db before Android starts on the next boot.
    If account_present was false above it should be true after the reboot; this
    ADB path never writes accounts.db on a running Android. Check:
      adb shell cat /data/june/logs/identity.log
      adb shell cat /data/june/identity_ensure.state
    The /system seed is what makes a factory reset self-heal.
TXT
  cat <<'TXT'

  problems[] should not contain component-*, cert-untrusted or cert-ip-*.
  It must also not contain identity-missing after the reboot.
  cert.fingerprint should match the leaf, and cert.ca_fingerprint the CA printed
  by this script:
TXT
  printf '    leaf sha256 fingerprint: %s\n' "$LEAF_FP"
  printf '    CA   sha256 fingerprint: %s\n' "$CA_FP"
  printf '    CA system-store file   : %s.0\n' "$CA_HASH"
  cat <<'TXT'

  Patch application logs (world-readable, written by june_reaper during boot):
    /data/june/logs/jcm_patch.log
    /data/june/logs/remotes_patch.log
    /data/june/logs/mediacapturer_patch.log
  Each should contain "applied: <sha256>" - or "already-applied" when the oven
  already ran that exact build. Read them over ADB:
    adb shell cat /data/june/logs/jcm_patch.log

== mDNS caveat ==

  The oven advertises <hostname>.local over Android's NsdService mDNS, and the
  leaf certificate carries that DNS name plus the install-time IP SAN. mDNS
  needs multicast on the same VLAN: guests/VLAN-isolated clients, some Android
  builds and many browsers will not resolve .local or cache a stale answer. When
  it does not resolve, use https://<install-ip>/ instead - that is exactly why
  the IP SAN is required by this script.

  If DHCP later moves the oven, that IP SAN is stale: /local then shows the
  amber problem "Oven IP changed since install", and clients that use the IP
  only will fail TLS until you re-run this deploy with certs for the new IP, or
  give the oven a static DHCP lease matching install_ip.

== Other caveats ==

  * /data staging is not persistent: a factory reset boots the SAP fallback
    system and loses the staged patches. Re-apply with the USB installer or this
    script afterwards. (Do not factory-reset this oven casually: it unpairs.)
  * This path needs the root adbd from the June Local boot image. It cannot make
    a stock oven rootable and never runs adb root.
  * Identity seed: this ADB path writes only the running /system (APP slot). A
    factory reset restores APP from SAP, so self-heal after a hard reset still
    needs the seed staged in SAP by the USB installer (a normal UMS install
    writes both slots). The running oven is seeded now, so /local/status
    recovers without a reset and the pre-Android ensure keeps the account row
    on every normal boot.
  * No boot image was flashed, no RCM was used and no factory reset happened.

== Restore / rollback ==
TXT
  printf '  Backups: %s\n' "$BACKUP_DIR"
  cat <<'TXT'
  To put the previous files back (only files that existed are in the backup):
    adb shell mount -o rw,remount /system
    adb shell /system/bin/busybox cp -p <backup>/june_leaf.crt /system/etc/june_leaf.crt
    adb shell /system/bin/busybox cp -p <backup>/june_leaf.key /system/etc/june_leaf.key
    adb shell /system/bin/busybox cp -p <backup>/june_ca.crt   /system/etc/june_ca.crt
    adb shell /system/bin/busybox cp -p <backup>/<hash>.0      /system/etc/security/cacerts/<hash>.0
    adb shell /system/bin/busybox cp -p <backup>/install.json  /data/june/install.json
    # identity files (only if they were in the backup):
    #   <backup>/token            -> /system/etc/june/identity/token
    #   <backup>/accounts_seed.db -> /system/etc/june/identity/accounts_seed.db
    #   <backup>/identity.json    -> /system/etc/june/identity/identity.json
    #   <backup>/data-identity.json -> /data/june/identity.json
    adb shell mount -o ro,remount /system
  Then reboot so /data/june/*_nopin.apk are no longer staged (remove them with
  adb shell rm -f if you want to keep the current app build).
TXT
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/june-adb-deploy.XXXXXX")" \
    || die "could not create a temporary directory"

  step "Checking host tools"
  host_checks

  step "Validating the payload"
  pad_path
  preflight_certs
  preflight_apks

  step "Locating the oven over ADB"
  select_device
  check_oven

  step "Reading the oven's current state"
  collect_state
  check_hostname_san
  collect_identity_state
  prepare_identity_assets

  step "Confirmation"
  confirm

  step "Backing up what will be replaced"
  make_backup

  step "Remounting /system read-write"
  remount_system_rw

  step "Removing stale /system staged patches"
  remove_stale_stage

  step "Pushing the payload"
  push_payload

  step "Verifying the payload on the oven"
  verify_payload

  step "Syncing and finishing"
  finish

  print_verification
  note "done: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

main "$@"
