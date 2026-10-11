# Notices

## June

June and June Oven are product names of June Life, Inc. They are used here
only to say which ovens this project works with. [Project July](https://project-july.org)
is an independent community project. It is not affiliated with, maintained by,
or endorsed by June Life or Weber, and all trademarks belong to their owners.

The installer exists so that people who own a June oven can keep using it
after the June cloud shuts down. June's own software is not part of this
repository: its APKs, firmware, certificates and keys are listed under
"Not included" in the [README](README.md) and must be supplied locally. The
recipes in [`apk-patches/`](apk-patches/) change copies of June's apps that
owners extract from their own ovens, so that those apps talk to a local server
instead of June's cloud.

## Third-party components

- **Barlow** fonts (`installer/liveiso/gui/web/fonts/`,
  `installer/usbtool/frontend/fonts/`), copyright The Barlow Project Authors,
  under the SIL Open Font License 1.1. The license is in `OFL.txt` next to
  the fonts.
- **Go modules** used by June USB (`installer/usbtool/go.mod`), such as Wails
  and go-diskfs, stay under their own licenses.
- The live ISO built from this repository contains **Debian** packages, each
  under its own license. **Ventoy** is not bundled; users download it from its
  own project.

Everything else in this repository is under the [MIT License](LICENSE).
