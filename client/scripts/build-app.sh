#!/usr/bin/env bash
# Builds Parallax.app into client/build/. Usage: scripts/build-app.sh [debug|release] [--open]
#
# Signing: set PARALLAX_SIGN_IDENTITY to a codesigning identity (see
# `security find-identity -v -p codesigning`). Without one the app is signed
# ad hoc, and macOS will re-ask for camera/mic/screen permission after each
# rebuild because the signature changes.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
OPEN="${2:-}"

source scripts/env.sh

swift build -c "$CONFIG" --product Parallax
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Parallax"

APP=build/Parallax.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Parallax"
cp Support/Info.plist "$APP/Contents/Info.plist"

IDENTITY="${PARALLAX_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --entitlements Support/Parallax.entitlements "$APP"
echo "Built $APP (signed with: $IDENTITY)"

if [[ "$OPEN" == "--open" ]]; then
  open "$APP"
fi
