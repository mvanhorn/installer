# Publishing the June Local installer

Everything that *builds* the installer lives in this folder, but the payload
inputs (June APKs, certificates, firmware blobs, prebuilt binaries) currently
come from sibling folders and must not all be committed to a public repo.

## What is in this folder

| Path | Kind | Publish |
|------|------|---------|
| `build.sh` | ISO build + the `june-menu` installer UI | yes |
| `build_live_iso.sh` | Docker wrapper, stamps `BUILD_ID` | yes |
| `prepare_assets.sh` | Generates `assets/` (embeds `install.sh` and `backup.sh`) | yes |
| `Dockerfile` | Debian live-build environment | yes |
| `flash_to_ventoy.sh` | Copies the ISO to a Ventoy stick | yes |
| `README.md`, `TEST_RUNBOOK.md`, `PUBLISHING.md` | docs | yes |
| `assets/` | Generated payload (binaries, APKs, certs) | no (regenerated) |
| `vm-record*/` | Local VM test recordings | no |

## Paths

`prepare_assets.sh` derives `LR` (the `local-resources` checkout) from its own
location and `ROOT` as its parent. Override with `JUNE_LR` / `JUNE_ROOT` when
the published tree has a different layout:

```sh
JUNE_LR=/path/to/local-resources JUNE_ROOT=/path/to/June ./prepare_assets.sh
```

## Payload inputs and where they come from today

| Input | Default source | Publish |
|-------|----------------|---------|
| `deploy_onoven.sh`, `june_bootclear.sh.onoven`, `june_reaper.sh.junelocal` | `june-arch/onoven/` | yes |
| `generate_certs.sh`, `sign_leaf.sh` | `june-arch/packaging/` | yes |
| `install.sh`, `backup.sh` | embedded in `prepare_assets.sh` | yes |
| `june-local`, `june-camerad` armv7 binaries | `june-arch/golocal/bin/` | prefer publishing `june-arch/golocal/` source |
| `companions_state.json` | `june-arch/` | yes |
| `boot_junelocal_init.img` | `june-arch/tools/orchestrator/` | no; publish `build_boot_junelocal_init.py` + `jcm_apply.sh` and build it |
| `JuneCloudMessaging.apk` | `june-rcm/healthy-build/…` | **no** (June proprietary) |
| `JuneCloudMessaging_nopin_signed.apk` | `june-arch/windows-work/jcm-pinning/` | **no** (modified June app) |
| `companion_endpoint_signed.apk` | `june-arch/windows-work/companion-endpoint/` | **no** |
| `junelife_chain_godaddy_intermediate.crt`, `june-local.key` | `June/tools/certs/` | **no** — contains June's private key |
| `tegrarcm`, `jetson-tk1.bct`, `u-boot-dtb-tegra.bin` | `june-rcm/` | no (June/NVIDIA firmware) |

## Suggested published layout

```
june-installer/
  liveiso/        # this folder
  onoven/         # deploy_onoven.sh, june_bootclear.sh.onoven, june_reaper.sh.junelocal
  packaging/      # generate_certs.sh, sign_leaf.sh
  bootimage/      # build_boot_junelocal_init.py, jcm_apply.sh
  golocal/        # june-local / june-camerad sources
  blobs/          # NOT committed: June APKs, certs/key, firmware blobs (fetched or supplied locally)
```

With that layout, set `JUNE_LR` to the published root and provide `blobs/`
locally (or download it from a restricted release) before running
`prepare_assets.sh`.
