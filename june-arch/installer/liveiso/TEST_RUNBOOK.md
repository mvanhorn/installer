# June Local live ISO - test runbook

Created: 2026-09-27 (US/Pacific)

## Current USB state

- Device: `/dev/sda` - 29.9G USB Flash Drive
- Boot setup: Ventoy 1.1.17
- ISO on Ventoy data partition: `june-local-live.iso`
- ISO SHA256:
  `0a4893374aca5d60f1c772c14953fc90e4fc85d18ba34f0397e10388af126b46`

The same USB stick is expected to hold both the installer ISO and any eMMC
backup images because Ventoy's exFAT partition is writable.

## Boot / smoke test

1. Reboot the laptop.
2. Boot from the USB drive via the laptop boot menu.
3. In Ventoy, select `june-local-live.iso`.
4. The live system should auto-login and auto-open the June Local menu.
5. Verify these menu choices exist:
   - Install June Local (recommended)
   - Install with per-home CA + leaf (advanced)
   - Backup oven to USB
   - Restore oven from USB
   - Check USB / disk status
   - Exit to a shell

If the menu does not auto-open, run:

```bash
june-menu
```

## Backup on the same Ventoy stick

- Expected backup filename:
  `june-oven-backup-YYYYMMDD-HHMMSS.img`
- Expected sidecar:
  `june-oven-backup-YYYYMMDD-HHMMSS.img.sha256`
- Backup size should be about 7.28 GiB.
- The backup can be restored later from the same Ventoy stick.

Known limitation:

- A raw `dd`/Etcher flash of the ISO is read-only, so same-stick backup only
  works when the USB was prepared with Ventoy.

## Rebuild commands

```bash
cd june-arch/installer/liveiso
bash ./prepare_assets.sh
bash ./build_live_iso.sh
```

Current build fix: `build_live_iso.sh` now uses a named Docker container plus
`docker cp` to extract `live-image-amd64.hybrid.iso`. The old bind-mounted-file
approach failed with `cp: failed to close '/out/june-local-live.iso'`.

## Raw flash alternative

```bash
sudo dd if=june-local-live.iso of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

Replace `/dev/sdX` with the USB device. This produces a plain installer USB,
not a same-stick backup USB.

## Ventoy setup on Linux

Ventoy release used: 1.1.17

To make the Ventoy stick auto-boot the June ISO instead of waiting at two
menus, put a `ventoy/ventoy.json` file on the Ventoy data partition. See:

`june-arch/installer/liveiso/ventoy.json.example`

The live ISO bootloader timeout was also reduced to 1 second in `build.sh`.

Download/extract:

```bash
curl -LO https://github.com/ventoy/Ventoy/releases/download/v1.1.17/ventoy-1.1.17-linux.tar.gz
tar xf ventoy-1.1.17-linux.tar.gz
```

Install to USB:

```bash
sudo ./Ventoy2Disk.sh -I /dev/sdX
```

Then copy `june-local-live.iso` to the Ventoy exFAT data partition.

Known fix: Ventoy needs `mkfs.vfat`, which comes from `dosfstools`.

```bash
sudo pacman -S dosfstools
```

## tegrarcm runtime library fix

`tegrarcm` is an x86_64 binary and must be built on Debian bookworm, not on
the Arch host. A host-built binary requests `GLIBCXX_3.4.32`, which bookworm's
libstdc++ does not provide.

The current `tegrarcm` is built in a Debian bookworm container and linked
against bookworm's libcrypto++/libstdc++. The live image also includes:

```text
libcrypto++8
libusb-1.0-0
libstdc++6
```

Verified in QEMU with:

```bash
ldd /opt/june-installer/tegrarcm
```

## Error logs

Menu runs log to `/tmp/june-*.log` and now copy successful/failed logs to:

```text
/run/live/medium/june-logs/
```

when the boot medium is writable (Ventoy). Those logs persist on the Ventoy
data partition after reboot.

## Outstanding decisions / reminders

- The June eMMC GPT is nonstandard: the primary GPT lives at LBA 29151/29183
  and LBA 1 is unused, so `sgdisk`/`gdisk` report a corrupt primary even though
  both GPT tables are valid and match. Raw backups are fine; do not "repair"
  them. APP/SAP/UDA ext4 superblocks are clean in the 261003-0759 backup.
- On the live boot USB, `/dev/sdX1` cannot be mounted directly (Ventoy/dm holds
  it, mount(2) returns EBUSY); `backup.sh` mounts it through a loop device and
  now also finds such mounts by scanning `losetup -j` output, so the Ventoy
  stick shows up as a backup destination and logs/certs persist there.
- The per-home CA only works for phone/HA pairing after the no-pin
  JuneCloudMessaging APK is applied on the oven. The applier must run during
  the *first* mount of the encrypted collector volume (patched
  `june_reaper.sh`); a late second EncFS read-write mount cannot work because
  the ciphertext lives on read-only /system. Status:
  `/data/june/logs/jcm_patch.log`.
- Installer default is still `prepackaged` (shared GoDaddy chain), not
  `generate`. If local HTTPS/IP certs become the default, this needs to change.
- `generate_certs.sh` already supports `JUNE_IP_SAN`; the IP is prompted for,
  not auto-detected.
- Plain HTTP listener is now on port `80` in the current oven service.
  Moving user-facing HTTP to port `80` is planned but not yet implemented.
- mDNS is not implemented. Multiple ovens will need service discovery, not a
  single fixed `.local` name.
- Home Assistant integration should default to plain HTTP by IP, with CA paste
  and TLS verification as opt-in/advanced only.
- Do not distribute or bundle a CA private key in the integration or installer.
- The old QEMU test VM was killed before this USB was finalized.

## Files changed recently

- `june-arch/installer/liveiso/build.sh`
- `june-arch/installer/liveiso/build_live_iso.sh`
- `june-arch/installer/liveiso/prepare_assets.sh`
- `june-arch/installer/liveiso/README.md`

These changes are not necessarily committed yet.
