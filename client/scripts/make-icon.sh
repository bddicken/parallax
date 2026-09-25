#!/usr/bin/env bash
# Renders Support/AppIcon.svg into Support/AppIcon.icns. Run after editing the SVG.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/env.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ICONSET="$TMP/AppIcon.iconset"
mkdir "$ICONSET"

# NSImage renders SVG natively, so no extra tools are needed.
cat > "$TMP/render.swift" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
let image = NSImage(contentsOfFile: args[1])!
for spec in args.dropFirst(2) {
  let parts = spec.split(separator: ":")
  let px = Int(parts[1])!
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
  NSGraphicsContext.restoreGraphicsState()
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: String(parts[0])))
}
SWIFT

SPECS=()
for size in 16 32 128 256 512; do
  SPECS+=("$ICONSET/icon_${size}x${size}.png:$size" "$ICONSET/icon_${size}x${size}@2x.png:$((size * 2))")
done
swift "$TMP/render.swift" Support/AppIcon.svg "${SPECS[@]}"
iconutil -c icns "$ICONSET" -o Support/AppIcon.icns
echo "Wrote Support/AppIcon.icns"
