#!/bin/bash
# The design beta, local, for QA before anything ships: the iPhone app in a simulator of its own and a
# Mac copy called "baud Beta", both on demo data, both on stores of their own, neither touching the
# real baud or the network beyond the update check.
#
#   scripts/design-beta.sh            build both, install the iPhone app, make the Mac copy, open both
#   scripts/design-beta.sh phone      open the iPhone app again, on the same store
#   scripts/design-beta.sh mac        open the Mac copy again, on the same store
#   scripts/design-beta.sh first-run  the iPhone app as on first run: the name screen, no demo
#   NO_BUILD=1 …                      use the apps already built
#   ME=name …                         the name the demo calls you (Robin by default)
#
# The Mac copy lives in build/design-beta/, never in /Applications. Its bundle id is
# sh.rubric.baud.mac.beta, its store build/design-beta/mac-store, and its keys only ever in that
# folder (AppModel: a `.beta` id never uses the keychain). It maps no router ports and relays for
# nobody. Double-click build/design-beta/baud Beta.app to open it again: the variables are in its own
# Info.plist (LSEnvironment). It answers no baud:// links: those stay with the real baud.
# scripts/design-beta-clean.sh takes all of it away again.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
WHAT=${1:-all}
BETA=$ROOT/build/design-beta
APP="$BETA/baud Beta.app"
ID=sh.rubric.baud.mac.beta
SIM_NAME="baud beta"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
NAME=${ME:-Robin}
mkdir -p "$BETA"; touch "$ROOT/build/.metadata_never_index"

# A simctl call that sometimes hangs (privacy, location), given `t` seconds and then left behind.
timed() {
  local t=$1; shift
  "$@" >/dev/null 2>&1 & local p=$!
  ( sleep "$t"; kill "$p" 2>/dev/null ) & local w=$!
  wait "$p" 2>/dev/null || true
  kill "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true
  return 0
}

build() {
  [ -n "${NO_BUILD:-}" ] && return
  echo "Building the Mac app…"
  xcodebuild -project baud.xcodeproj -scheme BaudMac -destination 'platform=macOS' -derivedDataPath build/DerivedData-beta-mac \
    CODE_SIGNING_ALLOWED=NO build > "$BETA/build-mac.log" 2>&1 || { tail -20 "$BETA/build-mac.log"; exit 1; }
  echo "Building the iPhone app…"
  xcodebuild -project baud.xcodeproj -scheme Baud -destination "platform=iOS Simulator,id=$(sim)" -derivedDataPath build/DerivedData-beta-ios \
    CODE_SIGNING_ALLOWED=NO build > "$BETA/build-ios.log" 2>&1 || { tail -20 "$BETA/build-ios.log"; exit 1; }
}

# The beta's own simulator: an iPhone 17 Pro on the newest iOS here, made the first time.
sim() {
  local id
  id=$(xcrun simctl list devices | grep "$SIM_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/' || true)
  if [ -z "$id" ]; then
    local runtime
    runtime=$(xcrun simctl list runtimes | grep -E '^iOS' | tail -1 | sed -E 's/.* - (com\.apple\.CoreSimulator\.SimRuntime\.[^ ]+).*/\1/')
    id=$(xcrun simctl create "$SIM_NAME" "iPhone 17 Pro" "$runtime" 2>/dev/null || xcrun simctl create "$SIM_NAME" "iPhone 16 Pro" "$runtime")
  fi
  echo "$id"
}

phone() { # fresh: a new store; first: no demo, no name
  local SIM; SIM=$(sim)
  local store=$BETA/phone-store
  xcrun simctl boot "$SIM" 2>/dev/null || true
  xcrun simctl bootstatus "$SIM" >/dev/null
  open -a Simulator --args -CurrentDeviceUDID "$SIM"
  if [ "${1:-}" = install ]; then
    xcrun simctl terminate "$SIM" sh.rubric.baud.ios 2>/dev/null || true
    xcrun simctl uninstall "$SIM" sh.rubric.baud.ios 2>/dev/null || true
    xcrun simctl install "$SIM" "$ROOT/build/DerivedData-beta-ios/Build/Products/Debug-iphonesimulator/baud.app"
    # No permission prompt in the way of the first look; a park for "here".
    timed 20 xcrun simctl privacy "$SIM" grant location sh.rubric.baud.ios
    timed 20 xcrun simctl location "$SIM" set 40.7812,-73.9665
    rm -rf "$store"
  fi
  xcrun simctl terminate "$SIM" sh.rubric.baud.ios 2>/dev/null || true
  if [ "${1:-}" = first ]; then
    local fresh=$BETA/first-run-store; rm -rf "$fresh"; mkdir -p "$fresh"
    env SIMCTL_CHILD_BAUD_DIR="$fresh" SIMCTL_CHILD_BAUD_CRATE=0 SIMCTL_CHILD_BAUD_NOTIFY=log \
      xcrun simctl launch "$SIM" sh.rubric.baud.ios >/dev/null
    echo "iPhone: first run, on a store of its own (no demo, no network)."
    return
  fi
  mkdir -p "$store"
  # Ana and Jo share where they are (the Friends map), and weekend has two replies an older baud
  # made in a thread (shown in the conversation now).
  env SIMCTL_CHILD_BAUD_DEMO=1 SIMCTL_CHILD_BAUD_NAME="$NAME" SIMCTL_CHILD_BAUD_DIR="$store" SIMCTL_CHILD_BAUD_NOTIFY=log \
    SIMCTL_CHILD_BAUD_DEMO_PLACES=1 SIMCTL_CHILD_BAUD_DEMO_THREAD=1 \
    xcrun simctl launch "$SIM" sh.rubric.baud.ios >/dev/null
  echo "iPhone: open in the \"$SIM_NAME\" simulator. The first launch takes about 20 seconds to fill the demo."
}

mac_copy() {
  local from=$ROOT/build/DerivedData-beta-mac/Build/Products/Debug/baud.app
  [ -n "${NO_BUILD:-}" ] && [ ! -d "$from" ] && from=$ROOT/build/DerivedData-design/Build/Products/Debug/baud.app
  pkill -f "$APP/Contents/MacOS/baud" 2>/dev/null && sleep 1 || true
  [ -d "$APP" ] && "$LSREG" -u "$APP" 2>/dev/null || true
  rm -rf "$APP" "$BETA/mac-store"; mkdir -p "$BETA/mac-store"
  cp -R "$from" "$APP"
  local plist=$APP/Contents/Info.plist
  plutil -replace CFBundleIdentifier -string "$ID" "$plist"
  plutil -replace CFBundleName -string "baud Beta" "$plist"
  plutil -replace CFBundleDisplayName -string "baud Beta" "$plist"
  # Links stay with the real baud.
  plutil -remove CFBundleURLTypes "$plist" 2>/dev/null || true
  # Its launch switches, so a double-click is the launcher: demo data, its own store, no port
  # mapping, no relaying, no notifications (it says what it would have shown in its log); Ana and
  # Jo sharing where they are, and weekend's two replies from an older baud's thread.
  plutil -replace LSEnvironment -json "{\"BAUD_DEMO\":\"1\",\"BAUD_NAME\":\"$NAME\",\"BAUD_DIR\":\"$BETA/mac-store\",\"BAUD_PORTMAP\":\"0\",\"BAUD_RELAY\":\"0\",\"BAUD_NOTIFY\":\"log\",\"BAUD_DEMO_PLACES\":\"1\",\"BAUD_DEMO_THREAD\":\"1\"}" "$plist"
  codesign --force --deep -s - "$APP" 2>/dev/null
  "$LSREG" -f "$APP"
}

mac() {
  [ -d "$APP" ] || mac_copy
  open "$APP"
  echo "Mac: \"baud Beta\" is open. Double-click $APP to open it again."
}

case $WHAT in
  all) build; phone install; mac_copy; mac ;;
  phone) phone ;;
  mac) mac ;;
  first-run) phone first ;;
  *) echo "usage: scripts/design-beta.sh [all|phone|mac|first-run]"; exit 2 ;;
esac
echo "When you're done: scripts/design-beta-clean.sh"
