# June Local live ISO

Builds a bootable Linux USB image that contains the installer so a Windows/macOS
friend only needs to flash one file and boot it.

## Build

```bash
cd installer/liveiso
# first copy the installer assets you want to ship into assets/
bash ./prepare_assets.sh
bash ./build_live_iso.sh
```

The host needs Docker or Podman (build runs `live-build` inside the container).

## Flash for friends

- **Ventoy is recommended** if the same USB stick should also hold an eMMC
  backup: Ventoy keeps a normal writable data partition alongside the boot
  files, so the backup image lands on the same stick and shows up in Windows
  for recovery.
- Balena Etcher also works, but a plain Etcher flash is read-only; in that case
  keep a separate USB drive available for backups.
- Boot the laptop from the USB.
- The live system auto-logs in and opens the **June Local installer menu**
  automatically. Follow the prompts.
- If the menu is closed or you need a shell, run `june-menu` to reopen it.

## Notes

- The ISO is a minimal Debian live environment with no desktop.
- The menu uses `whiptail` (a lightweight terminal UI), so it still feels like
  a guided installer without shipping a full X11 desktop.
- The installer auto-detects the June eMMC by size, explicitly skips the boot
  USB/system disk, and refuses to touch other disks.
- The menu also offers full eMMC **backup to USB** and **restore from USB**
  (the destination needs at least 8 GB free, and can be the Ventoy boot USB
  itself).
- Custom install now asks whether the JuneCloudMessaging patch payload should
  be staged in `/system` (persists across factory reset) or `/data` (does not).
  The app update is applied on the next boot by the June Local copy of
  `/system/bin/june_reaper.sh`: that is the stock script which mounts the
  encrypted `/system/priv-app` volume, and the June Local version mounts it
  read-write when a patch is staged, applies the patch before Android starts,
  then drops the one-shot `/data` staging copy. A status line is written to
  `/data/june/logs/jcm_patch.log` (world-readable). The boot image's
  `jcm_apply` service remains as a fallback; see
  [`docs/jcm-postboot-apply-runbook.md`](../../docs/jcm-postboot-apply-runbook.md).
- The standard install keeps the oven's factory JuneCloudMessaging app and
  never writes the factory APK under the patch name. Factory-reset persistence
  is opt-in there too (default off): when enabled, the no-pin JCM patch is
  staged in `/system` so it survives a factory reset.
- Both install flows ask for an oven name: the standard flow defaults to
  `june`, the custom flow to `june.local` (its IP field is prefilled with
  `192.168.1.`). The name is written to `/system/etc/june_hostname` and the
  boot script sets `net.hostname` from it, so Android advertises
  `<name>.local` over mDNS. Factory-reset persistence is a yes/no question and
  defaults to No.
- In the standard (prepackaged) install the name is mDNS-only: June's
  prepackaged certificate does not cover it, so HTTPS-by-name needs the custom
  (per-home CA) install, which puts the name in the certificate SAN.
- Optional for other devices on the network: point `api.junelife.com` and
  `messaging.junelife.com` at the oven's IP in local DNS (or a hosts file). The
  prepackaged certificate is a real certificate for those names, so even stock
  June clients verify there. The installer already writes the equivalent
  entries into the oven's own `/etc/hosts`.
- USB/oven connection guide: <https://project-july.org/setup>.
- `/opt/june-installer` on the live system contains `install.sh` and the deploy
  assets.
