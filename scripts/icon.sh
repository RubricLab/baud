#!/bin/bash
# Renders the icon from apps/icon (the family tile + baud's mark) into the asset catalog, the
# Mac .icns and the site. Run after changing Mark.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/icon"; rm -rf "$OUT"; mkdir -p "$OUT"
swiftc -O -parse-as-library -o "$OUT/AppIcon" "$ROOT"/apps/icon/*.swift
"$OUT/AppIcon" "$OUT"
iconutil -c icns "$OUT/baud.iconset" -o "$OUT/baud.icns"
SET="$ROOT/Resources/Assets.xcassets/AppIcon.appiconset"
cp "$OUT/icon-ios-1024.png" "$SET/icon-1024.png"
cp "$OUT/icon-mac-1024.png" "$SET/icon-mac-1024.png"
cp "$OUT/icon-mac-1024.png" "$ROOT/site/icon.png"
cp "$OUT/mark-224.png" "$ROOT/site/mark.png"
echo "✓ $SET, $OUT/baud.icns, site/icon.png, site/mark.png"
