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

# Prefer an explicit identity, then the one from setup-signing.sh, else ad hoc.
IDENTITY="${PARALLAX_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-identity -v -p codesigning | grep -q "Parallax Local Signing"; then
  IDENTITY="Parallax Local Signing"
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
  echo "note: signing ad hoc, so macOS will re-ask for permissions after each rebuild. Run scripts/setup-signing.sh once to fix."
fi
codesign --force --sign "$IDENTITY" --entitlements Support/Parallax.entitlements "$APP"
echo "Built $APP (signed with: $IDENTITY)"

if [[ "$OPEN" == "--open" ]]; then
  open "$APP"
fi
