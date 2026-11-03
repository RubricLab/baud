#!/bin/bash
# Takes the design beta away again, so that only the real /Applications/baud.app stays known to this
# Mac: quits "baud Beta", unregisters it from Launch Services, deletes its preferences, its saved
# window state and caches, its folder (the copy and both stores), takes the iPhone app off the beta
# simulator and shuts that down, then has Launch Services forget what's gone.
#
#   scripts/design-beta-clean.sh          all of the above
#   scripts/design-beta-clean.sh --sim    and delete the "baud beta" simulator too
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
BETA=$ROOT/build/design-beta
APP="$BETA/baud Beta.app"
ID=sh.rubric.baud.mac.beta
SIM_NAME="baud beta"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# The Mac copy.
pkill -f "$APP/Contents/MacOS/baud" 2>/dev/null && sleep 1
[ -d "$APP" ] && "$LSREG" -u "$APP"
defaults delete "$ID" >/dev/null 2>&1
rm -f "$HOME/Library/Preferences/$ID.plist"
rm -rf "$HOME/Library/Saved Application State/$ID.savedState" "$HOME/Library/Caches/$ID" "$HOME/Library/HTTPStorages/$ID" "$HOME/Library/HTTPStorages/$ID.binarycookies" "$HOME/Library/WebKit/$ID"
rm -rf "$BETA"
# Xcode registers what it builds: the beta's own build of the Mac app goes too.
"$LSREG" -u "$ROOT/build/DerivedData-beta-mac/Build/Products/Debug/baud.app" 2>/dev/null
rm -rf "$ROOT/build/DerivedData-beta-mac" "$ROOT/build/DerivedData-beta-ios"

# The iPhone app, on its own simulator.
SIM=$(xcrun simctl list devices | grep "$SIM_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
if [ -n "$SIM" ]; then
  xcrun simctl terminate "$SIM" sh.rubric.baud.ios 2>/dev/null
  xcrun simctl uninstall "$SIM" sh.rubric.baud.ios 2>/dev/null
  xcrun simctl shutdown "$SIM" 2>/dev/null
  [ "${1:-}" = --sim ] && xcrun simctl delete "$SIM" && echo "Deleted the \"$SIM_NAME\" simulator."
fi

"$LSREG" -gc 2>/dev/null
# What's left registered under baud's ids (the real app, and any dev build Xcode made).
left=$("$LSREG" -dump 2>/dev/null | grep -E "^path:.*baud[^/]*\.app" | grep -v CoreSimulator | sed -E 's/^path: *//; s/ \(0x[0-9a-f]+\)$//' | sort -u)
if echo "$left" | grep -q "design-beta"; then echo "The beta is still registered:"; echo "$left"; exit 1; fi
echo "The beta is gone. Still known to this Mac:"
echo "${left:-  (no baud app)}"
