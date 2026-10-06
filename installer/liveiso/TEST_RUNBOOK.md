# June Local live ISO - test runbook

Created: 2026-09-27 (US/Pacific)

## Current USB state

- Device: the 29.9G Ventoy USB Flash Drive (check `lsblk`; it moves between
  `/dev/sdX` names)
- Boot setup: Ventoy 1.1.17
- ISO on Ventoy data partition: `june-local-live.iso`
- Build: `20261005-0159-d8748b01`
- ISO SHA256:
  `9c74943fa2acf4f62ca1f0c0ebd66803c21ac7bce7d87fe0bfb15ad419bed76f`

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

## GUI dependency preflight (build-enforced)

The graphical installer uses `cage` (Wayland kiosk), `cog` (WPE WebKit), and
`seatd` for the DRM/VT seat. Debian bookworm's `cage` starts Xwayland by
default; without `/usr/bin/Xwayland` it exits before creating the Wayland
socket and the installer falls back to text.

`build.sh` now fails the ISO build if any of these are missing from the
chroot:

```
usr/bin/cage
usr/bin/cog
usr/sbin/seatd
usr/bin/Xwayland
```

It also checks that the kiosk command contains `cog --platform=wl`, that the
kiosk script has the Xwayland preflight, and that the live seat hook adds the
`video`/`render` groups. A successful build prints:

```
[+] GUI preflight OK: cage, cog, seatd, Xwayland present
```

The kiosk also checks for Xwayland and seatd at runtime; if either is missing
it writes a clear line to `/tmp/june-kiosk.log`, persists it to the boot USB
under `june-logs/`, and falls back to the text installer immediately.

## QEMU graphical-installer smoke test

After a build, boot the ISO headless with KVM:

```bash
qemu-system-x86_64 -enable-kvm -cpu host -m 4096 -smp 4 -machine q35 \
  -vga std -display none \
  -monitor unix:/tmp/june-qmon.sock,server,nowait \
  -cdrom june-local-live.iso -boot d
```

Wait for the live system to boot, then capture the screen:

```bash
echo 'screendump /tmp/june-screen.ppm' | socat - UNIX-CONNECT:/tmp/june-qmon.sock
ffmpeg -y -i /tmp/june-screen.ppm /tmp/june-screen.png
```

A pass is the June Local graphical home screen (“What would you like to do?”).
If it shows the text menu instead, copy `june-kiosk.log` from
`june-logs/` on the boot USB and check for:

- `Xwayland is missing` — the build preflight should have caught it;
- `cage watchdog: no Wayland socket` — compositor/seat problem;
- `amdgpu_cs_ctx_create2 failed` — GPU/render-node problem; the
  `auto` → `pixman` fallback should recover.

Known QEMU caveat (2026-10-06): with `-vga std` the guest gets `bochs-drm`,
which has no PRIME import support, so wlroots rejects it on both renderers
(`PRIME import not supported` / `Failed to open any DRM device`) and the
kiosk correctly falls back to the text menu.  That is a VM limitation, not an
installer bug — a QEMU build with `virtio-gpu` (or real hardware) is needed to
render the graphical installer.  To read the kiosk log from such a VM, boot
with `-kernel /tmp/june-vmlinuz -initrd /tmp/june-initrd.img -append
"boot=live components toram june.ui=gui console=ttyS0,115200"` and a
`-serial unix:...` socket.

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
cd installer/liveiso
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

`installer/liveiso/ventoy.json.example`

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

- `installer/liveiso/build.sh`
- `installer/liveiso/build_live_iso.sh`
- `installer/liveiso/prepare_assets.sh`
- `installer/liveiso/README.md`

These changes are not necessarily committed yet.
