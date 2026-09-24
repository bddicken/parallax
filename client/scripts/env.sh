# Sourced by the other scripts. With only the Command Line Tools installed
# (no Xcode), two things need help:
#  - The macOS 27 SDK implements SwiftUI's @State as a macro whose plugin
#    ships only with Xcode, so build against the 26.x SDK instead.
#  - swift-testing's macro plugin isn't found automatically in that setup.
SWIFT_FLAGS=()
if ! xcode-select -p 2>/dev/null | grep -q "Xcode"; then
  CLT=/Library/Developer/CommandLineTools
  if [[ -z "${SDKROOT:-}" && -d "$CLT/SDKs/MacOSX26.sdk" ]]; then
    export SDKROOT="$CLT/SDKs/MacOSX26.sdk"
  fi
  if [[ -d "$CLT/usr/lib/swift/host/plugins/testing" ]]; then
    SWIFT_FLAGS+=(-Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing")
  fi
fi
