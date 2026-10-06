# June Local installer mockups

Faithful renders of the real installer UI for the website tutorial.  These are
not hand-drawn approximations: `capture.py` starts the installer backend in
`--mock` mode and drives the actual HTML/CSS/JS with headless Chromium.

## Contents

- `png/` — the stage renders, named in tutorial order.
- `captions.md` — the stage list with suggested captions.
- `index.html` — a preview gallery using those captions.
- `capture.py` — regenerates everything from the current GUI source.

## Regenerate

```sh
python3 -m venv .venv
.venv/bin/pip install playwright
.venv/bin/playwright install chromium
.venv/bin/python capture.py
```

The script starts the mock backend on `127.0.0.1:8765` with `MOCK_SPEED=0.35`
and writes the PNGs into `png/`.  It expects the installer repo layout
(`installer/liveiso/gui/...` next to `website-assets/`).

Version and build id can be overridden:

```sh
JUNE_VERSION=0.5 JUNE_BUILD_ID=20261006-0123-26e73837 .venv/bin/python capture.py
```

## Stages

The order follows the basic/custom install journey: home, basic options,
persistence, custom options, connect (waiting), oven found with the 3 s
auto-start, installing, success with QR codes, backup destination, restore
confirmation, and the phone-access sheet.

## KVM verification (2026-10-06)

`vm-verify/` holds screendumps from the 0.5 release ISO booted in KVM with
`-device virtio-gpu-pci` (Arch splits the device into qemu-hw-display-virtio-gpu
+ qemu-hw-display-virtio-gpu-pci):

- `01-home-cursor.png` - graphical home screen; the cursor is visible even
  though the VM has no mouse, which verifies the uinput cursor nudge;
- `02-keyboard-focus.png` - Tab moves the focus ring across the tiles;
- `03-basic-options.png` - Enter opens the basic install options (oven name,
  persistence off by default).
