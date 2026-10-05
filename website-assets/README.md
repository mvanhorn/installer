# June Local website asset pack

Generated for the `CREATE_VENTOY_USB.md` and `USE_LIVE_INSTALLER.md` tutorials.
The `svg/` files are the editable source; `png/` files are rendered at 1920 px
wide for the website.

All screens marked **MOCKUP** are faithful reconstructions built from the real
installer copy, colors, and layout. They are not photographs. Replace them
with real screenshots when the tutorial photos are available.

## Index

| File | Use | Suggested caption / alt text |
| --- | --- | --- |
| `01-overview-flow.png` | Hero / top-of-page summary | “June Local on a Ventoy USB: download, create the stick, copy the files, boot, install or back up.” |
| `02-ventoy-windows.png` | Windows Ventoy step | “Ventoy2Disk on Windows: choose the USB, MBR, and Install. The result is VTOYEFI + an exFAT Ventoy partition.” |
| `03-ventoy-linux.png` | Linux Ventoy step | “Linux: install dosfstools and exfatprogs, then run Ventoy2Disk.sh against the whole disk.” |
| `04-usb-layout.png` | Partition / storage explainer | “What is on the stick: VTOYEFI, the exFAT Ventoy partition, the ISO, the config, logs, certs, and free space for the backup.” |
| `05-copy-and-config.png` | ISO + `ventoy.json` step | “Copy june-local-live.iso to the Ventoy partition and add ventoy/ventoy.json for a 3-second auto-select.” |
| `06-boot-menus.png` | Boot sequence explainer | “Two menus are expected: Ventoy first, then the June Local graphical/text menu.” |
| `07-secure-boot.png` | Secure Boot / MokManager step | “Handle Secure Boot by enrolling Ventoy’s key or disabling Secure Boot for the install.” |
| `08-backup-and-swap.png` | Backup storage explainer | “The live system runs from RAM. Keep the Ventoy stick for the backup, or swap in a second USB.” |
| `09-installer-ui.png` | Installer UI preview | “June Local installer home: Install June Local, Install with your own CA, Back up, Restore, and More.” |
| `10-troubleshooting.png` | Troubleshooting section | “Quick fixes: mkfs.vfat, ISO not listed, backup target missing, Secure Boot, no bootable device, slow backup.” |
| `11-install-options.png` | Basic install step | “Install June Local: keep the recommended defaults; persistence is optional.” |
| `12-connect-oven.png` | RCM connection step | “Connect the USB cable, hold SW2, power on for ~10 seconds; the installer detects RCM mode.” |
| `13-progress.png` | Running job | “Watch the percentage/elapsed time and tracker; keep the oven powered and connected.” |
| `14-success.png` | Install success | “June Local is installed: reboot the oven, open /local, then pair from the app or Home Assistant.” |
| `15-backup-destination.png` | Backup destination | “Choose the backup drive, folder, and file name; the Ventoy boot stick can be the target.” |
| `16-phone-access.png` | Phone UI | “Scan the QR code to run and follow the same installer from a phone.” |
| `17-text-mode.png` | Text UI fallback | “The basic text menu has the same jobs; use it if the graphical UI cannot start.” |
| `18-basic-vs-custom.png` | Mode comparison | “Basic keeps June's certificate and factory app; custom creates a per-home CA.” |
| `19-safety-checklist.png` | Safety card | “Do and don't list before pressing the final button.” |

`index.html` in this folder previews all of them with the same captions.
The `screenshots/` folder is the drop point for real phone/UI screenshots.

## Regenerating

```sh
sudo apt install librsvg2-bin
python3 generate_assets.py
```

## Getting real screenshots

The easiest real installer screenshots are from the phone UI:

1. Boot the live ISO on the installer laptop.
2. Open the installer’s **Phone setup** QR code.
3. Open the link on a phone and take screenshots of the home screen, the
   backup destination screen, and the running/finished job screens.

For the Ventoy screens, capture on the Windows or Linux machine that creates
the stick (Snipping Tool, GNOME Screenshot, Spectacle, etc.), then replace
`02-ventoy-windows.png`, `03-ventoy-linux.png`, and `06-boot-menus.png` if you
want real UI instead of the mockups.

## Current release example

The tutorial should always use the current release hash. Example for the
2026-10-05 build:

- Build: `20261005-0119-9130bb89`
- SHA256: `1221ff236835ca316eb279a29165e22801dac6594f68a12e5acb8b0e90bfa56a`

Project-specific facts to keep in the captions: **keep the Ventoy label**;
**exFAT or NTFS, never FAT32** (the oven backup is ~7.3 GB); leave ~8 GB free;
the live system runs from RAM (`toram`) so the boot USB can be swapped; logs
go to `june-logs/` and custom-install certs to `june-certs/`.
