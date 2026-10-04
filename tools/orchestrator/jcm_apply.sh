#!/system/bin/sh
# One-shot, post-boot JuneCloudMessaging patch applier.
#
# Runs from the boot ramdisk as root after `sys.boot_completed=1`.
# It reads the per-device EncFS password from /proc/collector, mounts the
# encrypted /system/collector overlay read-write at /data/jcm-rw, and replaces
# JuneCloudMessaging.apk with the staged patched APK.
#
# It is intentionally idempotent: if the live APK already matches the staged
# APK, it exits without touching anything. A future update is therefore the
# same operation: drop a new APK in the staging path and reboot, or run this
# script manually with --no-reboot.
#
# Staging paths (first match wins):
#   /system/etc/june/jcm_nopin.apk   -> persistent across factory reset
#   /data/june/jcm_nopin.apk         -> non-persistent staging

set -u

B=/system/bin/busybox
ENC=/system/bin/encfs
LOG=/data/june/logs/jcm_apply.log

logmsg() {
    echo "[jcm_apply] $*"
    echo "[jcm_apply] $*" >> "$LOG" 2>/dev/null || true
}

REBOOT=1
case "${1:-}" in
    --no-reboot|-n)
        REBOOT=0
        ;;
esac

if ! "$B" mkdir -p /data/june/logs /data/jcm-rw 2>/dev/null; then
    logmsg "could not create /data/jcm-rw"
    exit 1
fi

i=0
while [ "$i" -lt 60 ]; do
    if [ -r /proc/collector ] && "$B" mountpoint -q /system/priv-app 2>/dev/null; then
        break
    fi
    "$B" sleep 1
    i=$((i + 1))
done

if [ ! -r /proc/collector ]; then
    logmsg "/proc/collector did not appear after 60s; aborting"
    exit 1
fi
if ! "$B" mountpoint -q /system/priv-app 2>/dev/null; then
    logmsg "/system/priv-app is not mounted; aborting"
    exit 1
fi

src=""
for cand in /system/etc/june/jcm_nopin.apk /data/june/jcm_nopin.apk; do
    if [ -f "$cand" ]; then
        src="$cand"
        break
    fi
done
if [ -z "$src" ]; then
    logmsg "no staged JCM patch found; nothing to do"
    exit 0
fi

live=""
for cand in \
    /system/priv-app/JuneCloudMessaging/JuneCloudMessaging.apk \
    /system/priv-app/JuneCloudMessaging.apk
do
    if [ -f "$cand" ]; then
        live="$cand"
        break
    fi
done

src_hash=""
live_hash=""
src_out="$("$B" sha256sum "$src" 2>/dev/null)" || true
src_hash="${src_out%% *}"
if [ -n "$live" ]; then
    live_out="$("$B" sha256sum "$live" 2>/dev/null)" || true
    live_hash="${live_out%% *}"
fi
if [ -n "$src_hash" ] && [ -n "$live_hash" ] && [ "$src_hash" = "$live_hash" ]; then
    logmsg "JCM already matches staged patch ($src_hash); no-op"
    exit 0
fi

if ! "$B" mount -o rw,remount /system 2>/dev/null; then
    logmsg "could not remount /system read-write"
    exit 1
fi

collector_pass=""
IFS= read -r collector_pass < /proc/collector
if [ -z "$collector_pass" ]; then
    logmsg "empty /proc/collector password"
    "$B" mount -o ro,remount /system 2>/dev/null || true
    exit 1
fi

printf '%s\n' "$collector_pass" | \
    "$ENC" --paranoia --stdinpass --public -o rw \
    /system/collector /data/jcm-rw 2>/dev/null
enc_rc=$?
if [ "$enc_rc" -ne 0 ] || ! "$B" mountpoint -q /data/jcm-rw 2>/dev/null; then
    logmsg "EncFS read-write mount failed rc=$enc_rc"
    "$B" mount -o ro,remount /system 2>/dev/null || true
    exit 1
fi

dst=""
for cand in \
    /data/jcm-rw/JuneCloudMessaging/JuneCloudMessaging.apk \
    /data/jcm-rw/JuneCloudMessaging.apk
do
    if [ -f "$cand" ]; then
        dst="$cand"
        break
    fi
done
if [ -z "$dst" ]; then
    logmsg "JuneCloudMessaging.apk not found in decrypted collector"
    "$B" umount /data/jcm-rw 2>/dev/null || true
    "$B" mount -o ro,remount /system 2>/dev/null || true
    exit 1
fi

bak="$dst.jcmbak"
new="$dst.jcmnew"
applied=0

if "$B" cp "$dst" "$bak" && "$B" cp "$src" "$new"; then
    "$B" chmod 0644 "$new"
    new_out="$("$B" sha256sum "$new" 2>/dev/null)" || true
    new_hash="${new_out%% *}"
    if [ "$new_hash" = "$src_hash" ]; then
        if "$B" mv "$new" "$dst"; then
            "$B" rm -f "$bak" 2>/dev/null || true
            logmsg "JCM updated in EncFS collector ($src_hash)"
            applied=1
        else
            logmsg "failed to move staged JCM into place"
            "$B" rm -f "$new" "$bak" 2>/dev/null || true
        fi
    else
        logmsg "staged JCM verification failed; keeping original"
        "$B" rm -f "$new" "$bak" 2>/dev/null || true
    fi
else
    logmsg "could not back up or stage JCM"
    "$B" rm -f "$new" "$bak" 2>/dev/null || true
fi

"$B" sync
"$B" umount /data/jcm-rw 2>/dev/null || true
"$B" mount -o ro,remount /system 2>/dev/null || true

if [ "$applied" -ne 1 ]; then
    exit 1
fi

logmsg "JCM patch applied; rebooting"
if [ "$REBOOT" -eq 1 ]; then
    "$B" sync
    /system/bin/reboot
fi
exit 0
