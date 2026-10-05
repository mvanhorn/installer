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
onoven/              on-oven deploy scripts
                     deploy_onoven.sh, june_bootclear.sh.onoven,
                     june_reaper.sh.junelocal, oven-light/ (interior-light
                     bridge APK and smali source)
packaging/           certificate generation (generate_certs.sh, sign_leaf.sh)
tools/orchestrator/  boot image builder (build_boot_junelocal_init.py) and the
                     jcm_apply.sh fallback service
windows-work/        APK no-pin patch recipes (jcm-pinning, remotes-pinning,
                     mediacapturer-pinning, analytics-pinning)
```

Point `prepare_assets.sh` at this checkout with `JUNE_LR` (it defaults to the
repo root) plus the locally supplied blobs.

The camera/live-view/interior-light architecture is summarized in
[`CAMERA.md`](CAMERA.md).

## Build

`prepare_assets.sh` assembles the payload from this tree plus a few blobs that
are not in git (June APKs, certificates/keys, firmware, prebuilt armv7
binaries, the flashed boot image). See
`installer/liveiso/PUBLISHING.md` for the exact list.

```sh
cd installer/liveiso
JUNE_LR=<this-repo> JUNE_ROOT=<tree-with-tools/certs> bash prepare_assets.sh
bash build_live_iso.sh          # writes june-local-live.iso
```

`build_live_iso.sh` uses Docker (legacy builder) to run live-build. Copy the
resulting ISO to a Ventoy stick (`flash_to_ventoy.sh`), boot the target
machine from it, and follow the on-screen menu.

## Not included

- June APKs (`JuneCloudMessaging.apk`, `Remotes.apk`, companion endpoint)
- June's TLS key and the prepackaged GoDaddy chain
- NVIDIA/June firmware blobs (`tegrarcm`, `jetson-tk1.bct`, `u-boot-dtb-tegra.bin`)
- Prebuilt armv7 binaries (`june-local`, `june-camerad`) and the boot image

The recipes under `windows-work/` rebuild the patched apps from a
locally supplied factory APK. Keys and blobs must never be committed.
