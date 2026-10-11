# Real screenshots — drop folder

Put the real installer/phone screenshots here, then tell the Arch side and we
will wire them into `index.html` and `USE_LIVE_INSTALLER.md`.

Suggested names (phone portrait or landscape is fine; keep full resolution):

| Filename | Screen |
| --- | --- |
| `01-home.png` | Home: “What would you like to do?” with the five tiles. |
| `02-install-options.png` | Install June Local: persistence option, Next button. |
| `03-connect-oven.png` | “Put the oven in recovery mode” with the Oven found state. |
| `04-progress-install.png` | Install progress with percentage/elapsed and tracker. |
| `05-success-install.png` | “June Local is installed” + next steps. |
| `06-backup-destination.png` | “Where should the backup go?” with the drive list. |
| `07-progress-backup.png` | Backup progress with GiB, MB/s and tracker. |
| `08-success-backup.png` | “Backup saved” + file name and `.sha256` note. |
| `09-custom-ca.png` | Custom install address fields and/or CA download/QR. |
| `10-phone-access.png` | “Connect a phone” QR sheet with the toggle on. |
| `11-failure-retry.png` | A failure screen showing reasons and Try again. |
| `12-text-mode.png` | Basic text UI main menu (optional). |

Notes:

- The phone UI is the easiest way to capture real screens: boot the live ISO,
  open the installer’s **Phone setup** QR code, then use the phone.
- Avoid including personal network names, IPs, or serial numbers if the
  screenshots will be public.
- The current `png/` files are mockups built from the real installer copy and
  colors. Real screenshots can replace them one-for-one.

## June USB

`june-usb/` holds the June USB app screens used in `CREATE_USB.md` and on the
website. `03`–`06` are from a real run on Windows (a test build, hence the
"v0.5-bios-test" chip). `01` and `02` are rendered from the app's own UI with
its mock backend: serve `installer/usbtool/frontend/` and open
`?mock&screen=release` or `?mock&screen=drives` in a 1026 px wide window
(headless Edge or Chrome `--screenshot`); the drives shown there are examples.
