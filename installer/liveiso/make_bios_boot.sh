#!/usr/bin/env bash
# Build the legacy-BIOS boot code for a June USB stick.
#
# The June USB tool lays a stick out as MBR: partition 1 FAT32 "JUNEBOOT"
# starting at sector 2048, partition 2 exFAT "JUNE" for backups.  UEFI boots
# the ISO's own shim + signed GRUB from partition 1.  Legacy BIOS boots GRUB
# from the first MiB of the stick, which this script prepares:
#
#   june-bios.img  first 1 MiB of a stick: GRUB boot.img in sector 0 (only the
#                  first 440 bytes are meaningful; the tool keeps the stick's
#                  own partition table) and core.img from sector 1 onward.
#   i386-pc/       GRUB modules that core.img loads at runtime.
#
# Both land in the ISO under /boot/grub/ (config/includes.binary), so the boot
# code always matches the GRUB modules of the same release.  core.img finds
# its partition by searching for /boot/grub/june-bios.img and then reads the
# ISO's normal /boot/grub/grub.cfg, so BIOS and UEFI share one menu.
#
# Usage: make_bios_boot.sh OUTDIR   (needs grub-pc-bin and fdisk/sfdisk)
set -euo pipefail

out="${1:?usage: make_bios_boot.sh OUTDIR}"
grubdir=/usr/lib/grub/i386-pc
[ -f "$grubdir/boot.img" ] || { echo "grub-pc-bin is not installed ($grubdir/boot.img missing)" >&2; exit 1; }
# Debian ships grub-bios-setup in /usr/sbin, Ubuntu only in the GRUB lib dir.
bios_setup="$(command -v grub-bios-setup || echo "$grubdir/grub-bios-setup")"

# grub-bios-setup cannot resolve files on tmpfs, so avoid /tmp.
work="$(mktemp -d /var/tmp/june-bios.XXXXXX)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

cat > "$work/early.cfg" <<'EOF'
search --no-floppy --set=root --file /boot/grub/june-bios.img
set prefix=($root)/boot/grub
EOF

grub-mkimage -O i386-pc -o "$work/core.img" -c "$work/early.cfg" -p /boot/grub \
  biosdisk part_msdos fat search search_fs_file configfile normal test

# The tool writes june-bios.img into sectors 0..2047, so core.img must fit
# between sector 1 and the start of partition 1.
core_sectors=$(( ( $(stat -c %s "$work/core.img") + 511 ) / 512 ))
if [ "$core_sectors" -gt 2000 ]; then
  echo "core.img is $core_sectors sectors; it does not fit before sector 2048" >&2
  exit 1
fi

# Let grub-bios-setup patch boot.img and core.img against a disk image that
# has exactly the layout the tool creates; then keep its first MiB.
truncate -s 64M "$work/disk.img"
printf 'label: dos\nstart=2048, size=60M, type=c, bootable\n' | sfdisk -q "$work/disk.img"
cp "$grubdir/boot.img" "$work/boot.img"
printf '(hd0) %s\n' "$work/disk.img" > "$work/device.map"
"$bios_setup" --skip-fs-probe --force -d "$work" -b boot.img -c core.img \
  -m "$work/device.map" "$work/disk.img"

dd if="$work/disk.img" of="$out/june-bios.img" bs=1M count=1 status=none
rm -rf "$out/i386-pc"
mkdir -p "$out/i386-pc"
cp "$grubdir"/*.mod "$grubdir"/*.lst "$out/i386-pc/"
# BIOS GRUB loads "unicode" from $prefix/fonts/; without it config.cfg's
# loadfont fails and the menu falls back to plain text.
mkdir -p "$out/fonts"
cp /usr/share/grub/unicode.pf2 "$out/fonts/"
echo "BIOS boot code: $out/june-bios.img (core.img $core_sectors sectors), modules: $out/i386-pc/"
