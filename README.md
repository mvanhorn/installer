# June Local — installer

Source for the June Local installer: a minimal Debian live image that
provisions a June oven to talk to a local June server instead of June's cloud.
It flashes the oven over USB (RCM/UMS), installs the local service and
certificates, optionally generates a per-home CA, and can back up or restore
the oven's eMMC.

This repository is the publishable subset of the development tree. Proprietary
June blobs, firmware and private keys are **not** included; see
`installer/liveiso/PUBLISHING.md` for the full input list and what
must be supplied locally.

## Layout

```
installer/liveiso/   build the ISO (Docker + live-build) and the installer menu
golocal/             Go source for june-local and june-camerad (make oven,
                     make camerad); prebuilt binaries are not committed
onoven/              on-oven deploy scripts
                     deploy_onoven.sh, june_bootclear.sh.onoven,
                     june_reaper.sh.junelocal, oven-light/ (interior-light
                     bridge APK and smali source)
packaging/           certificate generation (generate_certs.sh, sign_leaf.sh)
tools/orchestrator/  boot image builder (build_boot_junelocal_init.py) and the
                     jcm_apply.sh fallback service
windows-work/        APK patch recipes (jcm/remotes/mediacapturer/analytics
                     no-pin, chef-cookmodes remote primitive whitelist +
                     plan_index)
```

Point `prepare_assets.sh` at this checkout with `JUNE_LR` (it defaults to the
repo root) plus the locally supplied blobs.

The camera/live-view/interior-light architecture is summarized in
[`CAMERA.md`](CAMERA.md).
The end-user USB recipe (Ventoy, Secure Boot, backup/log/cert layout) is in
[`CREATE_VENTOY_USB.md`](CREATE_VENTOY_USB.md).
The live installer walkthrough (basic/custom install, backup, restore, phone
UI, text mode) is in [`USE_LIVE_INSTALLER.md`](USE_LIVE_INSTALLER.md).
Website tutorial screenshots and mockups are in [`website-assets/`](website-assets/)
(SVG source, 1920 px PNGs, and an `index.html` preview).

## Build

`prepare_assets.sh` assembles the payload from this tree plus a few blobs that
are not in git (June APKs, certificates/keys, firmware, prebuilt armv7
binaries, the flashed boot image). See
`installer/liveiso/PUBLISHING.md` for the exact list.

```sh
cd golocal && make oven camerad && cd ..   # build the armv7 binaries
cd installer/liveiso
JUNE_LR=<this-repo> JUNE_ROOT=<tree-with-tools/certs> bash prepare_assets.sh
bash build_live_iso.sh          # writes june-local-live.iso
```

`build_live_iso.sh` uses Docker (legacy builder) to run live-build. Copy the
resulting ISO to a Ventoy stick (`flash_to_ventoy.sh`), boot the target
machine from it, and follow the on-screen menu.

Remote toast levels and the other non-bake primitives need the optional Chef
patch. Build it from your own extracted Chef APK with
`windows-work/chef-cookmodes/build_patched.sh`; `prepare_assets.sh` picks up
`Chef_cookmodes_signed.apk` when it is present and the installer stages it
through the same boot-time applier as the other patched priv-apps. Without it
the installer leaves the stock Chef whitelist in place.

## Not included

- June APKs (`JuneCloudMessaging.apk`, `Remotes.apk`, companion endpoint)
- June's TLS key and the prepackaged GoDaddy chain
- NVIDIA/June firmware blobs (`tegrarcm`, `jetson-tk1.bct`, `u-boot-dtb-tegra.bin`)
- Prebuilt armv7 binaries (`june-local`, `june-camerad`) and the boot image
- The stock and patched Chef APK (`Chef.apk` / `Chef_cookmodes_signed.apk`)

The recipes under `windows-work/` rebuild the patched apps from a
locally supplied factory APK. Keys and blobs must never be committed.
