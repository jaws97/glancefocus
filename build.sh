#!/usr/bin/env bash
# Builds build/GlanceFocus.app. Run `bash build.sh install` to also copy it to /Applications,
# or to ~/Applications when this account can't write to /Applications (common on work Macs).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="GlanceFocus"
APP="build/${APP_NAME}.app"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature: enough to run on your own Mac with camera access under the hardened runtime.
codesign --force --options runtime --entitlements Resources/GlanceFocus.entitlements --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  DEST="/Applications"
  [[ -w "$DEST" ]] || DEST="$HOME/Applications"
  mkdir -p "$DEST"
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "$DEST/${APP_NAME}.app"
  cp -R "$APP" "$DEST/"
  echo "Installed $DEST/${APP_NAME}.app"
fi
