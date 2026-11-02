#!/bin/bash
# baud for iOS → TestFlight: archive with automatic signing, export for App Store Connect, upload.
#   ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=/abs/AuthKey_….p8 scripts/ship-ios.sh
# Without ASC_KEY_ID it uses the Xcode account signed in for the team and only exports the .ipa.
# Needs the app record sh.rubric.baud.ios in App Store Connect (My Apps → +); the API cannot create it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/ship-ios"
BUILD_NUMBER=$(date -u +%Y%m%d%H%M)
rm -rf "$OUT"; mkdir -p "$OUT"
(cd "$ROOT" && xcodegen generate --quiet)
KEY=()
[ -n "${ASC_KEY_ID:-}" ] && KEY=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
echo "▸ archive (build $BUILD_NUMBER)"
xcodebuild -project "$ROOT/baud.xcodeproj" -scheme Baud -configuration Release -destination 'generic/platform=iOS' \
	-archivePath "$OUT/baud.xcarchive" -allowProvisioningUpdates "${KEY[@]+"${KEY[@]}"}" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" -quiet archive
METHOD=app-store-connect; DEST=upload; [ -n "${ASC_KEY_ID:-}" ] || DEST=export
[ "${EXPORT_ONLY:-0}" = 1 ] && DEST=export
cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>method</key><string>$METHOD</string>
	<key>destination</key><string>$DEST</string>
	<key>teamID</key><string>${TEAM_ID:-J43C4UHCR4}</string>
	<key>uploadSymbols</key><true/>
</dict></plist>
PLIST
echo "▸ export ($DEST)"
xcodebuild -exportArchive -archivePath "$OUT/baud.xcarchive" -exportOptionsPlist "$OUT/export.plist" -exportPath "$OUT/export" \
	-allowProvisioningUpdates "${KEY[@]+"${KEY[@]}"}" -quiet
echo "✓ build $BUILD_NUMBER → $DEST ($OUT/export)"
