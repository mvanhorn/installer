#!/usr/bin/env bash
# Copy the installer's stylesheet, fonts and icon into June USB, so both
# apps look the same.  Run after changing installer/liveiso/gui/web.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
web="$here/../liveiso/gui/web"
cp "$web/app.css" "$web/favicon.svg" "$here/frontend/"
mkdir -p "$here/frontend/fonts"
cp "$web"/fonts/* "$here/frontend/fonts/"
echo "Synced app.css, favicon.svg and fonts/ from $web"
