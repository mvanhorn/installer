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
| `deploy_onoven.sh`, `june_bootclear.sh.onoven`, `june_reaper.sh.junelocal` | `onoven/` | yes |
| `generate_certs.sh`, `sign_leaf.sh` | `packaging/` | yes |
| `install.sh`, `backup.sh` | embedded in `prepare_assets.sh` | yes |
| `june-local`, `june-camerad` armv7 binaries | `golocal/bin/` | prefer publishing `golocal/` source |
| `companions_state.json` | repo root (supplied blob) | yes |
| `boot_junelocal_init.img` | `tools/orchestrator/` | no; publish `build_boot_junelocal_init.py` + `jcm_apply.sh` and build it |
| `JuneCloudMessaging.apk` | `june-rcm/healthy-build/…` | **no** (June proprietary) |
| `JuneCloudMessaging_nopin_signed.apk` | `windows-work/jcm-pinning/` | **no** (modified June app) |
| `companion_endpoint_signed.apk` | `windows-work/companion-endpoint/` | **no** |
| `junelife_chain_godaddy_intermediate.crt`, `june-local.key` | `June/tools/certs/` | **no** — contains June's private key |
| `tegrarcm`, `jetson-tk1.bct`, `u-boot-dtb-tegra.bin` | `june-rcm/` | no (June/NVIDIA firmware) |
| `upstream-content/` (presets/recipes mirror, ~287 MB) | `upstream-content/` (or `JUNE_CONTENT_DIR`) | **no** — June/third-party content, reference only |

The preset/recipe mirror is what makes guided programs (Proof, Slow Cook,
recipes) work: june-local serves `POST /1/presets/catalog` and
`GET /1/presets/bundle/...` from it. `prepare_assets.sh` includes it when
`JUNE_CONTENT_DIR` (default `upstream-content/`, falling back to the development
tree's `june-arch/capture/upstream-content`) exists, so
personal builds get working guided programs; published builds should omit it
for licensing reasons and document that users must supply their own content.

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

## Releasing an ISO

The download filename is always `june-local-live.iso`, so the Ventoy setup
(`ventoy.json` pins `/june-local-live.iso`) never changes.  The version lives
in the download URL and inside the ISO: boot menu entries, the GUI header,
the text menu, and every install/backup log.

1. Tag the release commit: `git tag v0.6 && git push origin v0.6`.
   `build_live_iso.sh` stamps `git describe` into `assets/VERSION`, so the
   tagged commit builds as `v0.6`; anything else builds as e.g.
   `v0.6-3-g9a0350c` (`-dirty` with uncommitted changes) and is clearly not a
   release.  `JUNE_VERSION=...` overrides it.
2. `./prepare_assets.sh && ./build_live_iso.sh`, then boot-test the ISO.
3. `sha256sum june-local-live.iso`.
4. Upload to R2 as `installer/v0.6/june-local-live.iso`.  Never overwrite a
   published version; old versions stay downloadable.
5. Point the `https://downloads.project-july.org/installer/latest` redirect
   (302) at the new object.
6. Update the SHA256 on the website and in `CREATE_VENTOY_USB.md`.
