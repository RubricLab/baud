#!/bin/bash
# baud.app outside the App Store: Release build, Developer ID signing (hardened runtime),
# notarization, stapling, and a signed, notarized, stapled .dmg.
#
#   ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=/abs/AuthKey_….p8 scripts/ship-mac.sh
#
# Env:
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH   App Store Connect API key (notarytool), or
#   NOTARY_PROFILE=<name>                     from `xcrun notarytool store-credentials`.
#   IDENTITY        signing identity (default: the team's Developer ID Application certificate);
#                   IDENTITY=- is an ad-hoc dry run of the whole path (implies SKIP_NOTARIZE=1).
#   SKIP_NOTARIZE=1 sign and package only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/ship-mac"
TEAM_ID="${TEAM_ID:-J43C4UHCR4}"
IDENTITY="${IDENTITY:-Developer ID Application: Rubric Labs Inc. ($TEAM_ID)}"
[ "$IDENTITY" = "-" ] && SKIP_NOTARIZE=1
TS=(--timestamp); [ "$IDENTITY" = "-" ] && TS=()
VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' "$ROOT/project.yml")

if [ "$IDENTITY" != "-" ] && ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
	echo "✗ No \"$IDENTITY\" in the keychain. Xcode → Settings → Accounts → Rubric Labs Inc. → Manage Certificates → + → Developer ID Application."
	exit 1
fi

echo "▸ build $VERSION (Release, unsigned)"
rm -rf "$BUILD"; mkdir -p "$BUILD"; touch "$BUILD/.metadata_never_index"
(cd "$ROOT" && xcodegen generate --quiet)
xcodebuild -project "$ROOT/baud.xcodeproj" -scheme BaudMac -configuration Release -destination "generic/platform=macOS" \
	-derivedDataPath "$BUILD/DerivedData" CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO -quiet build
APP="$BUILD/baud.app"
cp -R "$BUILD/DerivedData/Build/Products/Release/baud.app" "$APP"

sign() { codesign --force "${TS[@]+"${TS[@]}"}" --options runtime -s "$IDENTITY" "$@"; }
echo "▸ sign"
sign --entitlements "$ROOT/apps/mac/BaudMac.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -1

echo "▸ smoke: a copy under a bundle id of its own launches, seeds demo people, photographs itself and quits"
# The copy gets a bundle id of its own (sh.rubric.baud.mac.smoke.<time>) with its own store, so
# the smoke never touches, kills or collides with a baud the user is running from /Applications,
# nor with the dev build, nor with any window state macOS keeps per bundle id (a stale one from
# a killed dev instance kept the app from opening any window at all, 2026-10-08).
SHOTS="$BUILD/shots"; rm -rf "$SHOTS"; mkdir -p "$SHOTS"
SMOKE="$BUILD/smoke/baud.app"; rm -rf "$BUILD/smoke"; mkdir -p "$BUILD/smoke"; cp -R "$APP" "$SMOKE"
plutil -replace CFBundleIdentifier -string "sh.rubric.baud.mac.smoke.$(date +%s)" "$SMOKE/Contents/Info.plist"
sign --entitlements "$ROOT/apps/mac/BaudMac.entitlements" "$SMOKE"
pkill -f "$SMOKE/Contents/MacOS/baud" 2>/dev/null || true
if BAUD_DIR="$BUILD/smoke/data" BAUD_DEMO=1 BAUD_NAME=Smoke BAUD_APPEARANCE=light BAUD_SHOTS="$SHOTS" timeout 60 "$SMOKE/Contents/MacOS/baud" >"$BUILD/smoke.log" 2>&1 && [ -s "$SHOTS/mac-dm.png" ]; then
	echo "  healthy ($(ls "$SHOTS" | wc -l | tr -d ' ') shots)"
else
	echo "✗ The signed app did not come up and photograph itself; see $BUILD/smoke.log"; exit 1
fi

notarize() {
	if [ -n "${NOTARY_PROFILE:-}" ]; then xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
	else xcrun notarytool submit "$1" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait; fi
}
if [ "${SKIP_NOTARIZE:-0}" != 1 ]; then
	[ -n "${NOTARY_PROFILE:-}" ] || { : "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}" "${ASC_KEY_PATH:?set ASC_KEY_PATH}"; }
	echo "▸ notarize the app"
	ditto -c -k --keepParent "$APP" "$BUILD/baud.zip"
	notarize "$BUILD/baud.zip"
	xcrun stapler staple "$APP"
fi

echo "▸ dmg"
DMG="$BUILD/baud-$VERSION.dmg"; STAGE="$BUILD/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "baud" -srcfolder "$STAGE" -ov -format UDZO "$DMG"; rm -rf "$STAGE"
# A diskimages-helper can keep the new image attached; notarytool then hangs opening it.
for dev in $(hdiutil info | awk -v d="$DMG" '$0 ~ "image-path *: "d"$" {f=1} f && /^\/dev\/disk[0-9]+[ \t]/ {print $1; f=0}'); do hdiutil detach -quiet "$dev" || true; done
codesign --force "${TS[@]+"${TS[@]}"}" -s "$IDENTITY" "$DMG"
if [ "${SKIP_NOTARIZE:-0}" != 1 ]; then
	echo "▸ notarize the dmg"
	notarize "$DMG"; xcrun stapler staple "$DMG"
	spctl -a -t open --context context:primary-signature -v "$DMG"
	spctl -a -t exec -vv "$APP"
fi
shasum -a 256 "$DMG" | tee "$DMG.sha256"
SHA=$(cut -d' ' -f1 "$DMG.sha256")
printf '{"version":"%s","dmg":"https://baud.rubric.sh/baud-%s.dmg","sha256":"%s","notes":"https://baud.rubric.sh/#releases"}\n' "$VERSION" "$VERSION" "$SHA" > "$BUILD/releases.json"
echo "✓ $DMG"
