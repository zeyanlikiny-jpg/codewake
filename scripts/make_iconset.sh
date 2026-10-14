#!/bin/bash
# Build the AppIcon.appiconset from a single 1024px master.
# Regenerates icon art then emits all sizes using the existing macOS catalog.
set -euo pipefail
cd "$(dirname "$0")/.."

MASTER="Resources/icon_1024.png"
SET="Resources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$SET"

echo "→ rendering master icon"
swift scripts/make_icon.swift "$MASTER"

emit() { # size filename
  sips -z "$1" "$1" "$MASTER" --out "$SET/$2" >/dev/null
}
echo "→ emitting sizes"
# Keep every shipped catalog filename stable when replacing the app artwork.
for size in 16 32 128 256 512; do
  emit "$size" "icon_${size}@1x.png"
  emit "$((size * 2))" "icon_${size}@2x.png"
done
echo "✓ AppIcon.appiconset ready"
