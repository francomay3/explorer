#!/bin/bash
# Builds Explorer.app, installs it to /Applications, and opens that copy.
# Launchpad launches /Applications, so opening the repo copy as well starts a second app.
set -euo pipefail
cd "$(dirname "$0")/.."

killall Explorer >/dev/null 2>&1 || true
sleep 0.2

swift build
BIN="$(swift build --show-bin-path)/Explorer"
APP=".build/Explorer.app"
INSTALLED="/Applications/Explorer.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Explorer"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Support/en.lproj Support/es.lproj "$APP/Contents/Resources/"
chmod +x "$APP/Contents/MacOS/Explorer"
# An ad-hoc signature pins the code hash, which changes every build, so macOS forgets the Full Disk Access grant.
# Pinning the requirement to the bundle id keeps the grant valid across rebuilds.
REQ='designated => identifier "dev.framay.explorer"'
codesign --force --sign - -r="$REQ" "$APP"

rm -rf "$INSTALLED" Explorer.app
ditto "$APP" "$INSTALLED"
codesign --force --sign - -r="$REQ" "$INSTALLED"
open "$INSTALLED"
