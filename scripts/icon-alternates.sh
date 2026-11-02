#!/bin/bash
# Renders the icon with the mark in each swatch's colour into the asset catalog: AppIcon-<name>
# (iOS alternate icons) and IconMac-<name> (the Mac's live Dock icon). The main icon is untouched.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/icon-alt"; rm -rf "$OUT"; mkdir -p "$OUT"
swiftc -O -parse-as-library -o "$OUT/AppIcon" "$ROOT"/apps/icon/*.swift
"$OUT/AppIcon" "$OUT" alternates
CAT="$ROOT/Resources/Assets.xcassets"
for f in "$OUT"/AppIcon-*.png; do
  n=$(basename "$f" .png); mkdir -p "$CAT/$n.appiconset"; cp "$f" "$CAT/$n.appiconset/icon.png"
  printf '{ "images" : [ { "filename" : "icon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ], "info" : { "author" : "xcode", "version" : 1 } }\n' > "$CAT/$n.appiconset/Contents.json"
done
for f in "$OUT"/IconMac-*.png; do
  n=$(basename "$f" .png); mkdir -p "$CAT/$n.imageset"; cp "$f" "$CAT/$n.imageset/icon.png"
  printf '{ "images" : [ { "filename" : "icon.png", "idiom" : "mac" } ], "info" : { "author" : "xcode", "version" : 1 } }\n' > "$CAT/$n.imageset/Contents.json"
done
echo "✓ $(ls -d "$CAT"/AppIcon-*.appiconset | wc -l | tr -d ' ') alternates, $(ls -d "$CAT"/IconMac-*.imageset | wc -l | tr -d ' ') Mac icons"
