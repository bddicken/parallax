#!/usr/bin/env bash
# Builds Parallax.app into client/build/. Usage: scripts/build-app.sh [debug|release] [--open]
#
# Signing: uses PARALLAX_SIGN_IDENTITY if set, else the "Parallax Local
# Signing" certificate from scripts/setup-signing.sh, else ad hoc. Ad hoc
# signatures change every build, so macOS re-asks for permissions each time.
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
# Unique build number, so each build is distinguishable (About box, crash logs).
plutil -replace CFBundleVersion -string "$(date +%Y%m%d.%H%M%S)" "$APP/Contents/Info.plist"

# Prefer an explicit identity, then the one from setup-signing.sh, else ad hoc.
IDENTITY="${PARALLAX_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-identity -v -p codesigning | grep -q "Parallax Local Signing"; then
  IDENTITY="Parallax Local Signing"
fi
REQUIREMENTS=()
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
  # Ad hoc signatures default to requiring this exact binary (its cdhash), so
  # macOS forgets permission grants on every rebuild. Pin the requirement to
  # the bundle ID instead so rebuilt copies count as the same app.
  REQUIREMENTS=(--requirements '=designated => identifier "com.bddicken.parallax"')
fi
codesign --force --sign "$IDENTITY" "${REQUIREMENTS[@]}" --entitlements Support/Parallax.entitlements "$APP"
echo "Built $APP (signed with: $IDENTITY)"

if [[ "$OPEN" == "--open" ]]; then
  open "$APP"
fi
