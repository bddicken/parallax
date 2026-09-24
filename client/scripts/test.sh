#!/usr/bin/env bash
# Runs the client test suite. Extra args go to `swift test` (e.g. --filter DSP).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
swift test "${SWIFT_FLAGS[@]}" "$@"
