#!/bin/bash
# Pictures of every screen for the design pass, on demo data, without touching anyone's screen:
# the Mac app walks its own screens hidden (`BAUD_HIDDEN=1`, drawn offscreen by `BAUD_SHOTS`), the
# iPhone app is relaunched per screen in a simulator of its own, and the call screen draws every
# state (`BAUD_CALL_SHOTS`). Run from the repo root after building both Debug apps.
#
#   OUT=build/design-audit/before scripts/design-shots.sh [mac] [ios] [calls]
#   ACCENTS="none 0090FF" MODES="light dark" STEPS=dm,home  SCREENS="chats Sam:chats"  ME=name
#
# The Mac copy runs under its own bundle id (sh.rubric.baud.mac.design) and BAUD_DIR, with no port
# mapping and no relaying, and is unregistered and its preferences deleted when it's done.
set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUT=${OUT:-$ROOT/build/design-audit/shots}; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
WHAT=${*:-mac ios calls}
MAC_BUILD=${MAC_BUILD:-$ROOT/build/DerivedData-design/Build/Products/Debug/baud.app}
IOS_BUILD=${IOS_BUILD:-$ROOT/build/DerivedData-design-ios/Build/Products/Debug-iphonesimulator/baud.app}
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
SIM_NAME=${SIM_NAME:-baud design}
ID=sh.rubric.baud.mac.design
TMP=$ROOT/build/design-audit/tmp; mkdir -p "$TMP"

mac_copy() {
  APP=$ROOT/build/design-audit/app/baud.app
  rm -rf "$APP"; mkdir -p "$(dirname "$APP")"
  cp -R "$MAC_BUILD" "$APP"
  plutil -replace CFBundleIdentifier -string "$ID" "$APP/Contents/Info.plist"
  codesign --force -s - "$APP" 2>/dev/null
  # Hidden runs of an unregistered copy open no window at all.
  "$LSREG" -f "$APP"
}

mac_clean() {
  "$LSREG" -u "$ROOT/build/design-audit/app/baud.app" 2>/dev/null
  defaults delete "$ID" 2>/dev/null
  rm -f "$HOME/Library/Preferences/$ID.plist"
  rm -rf "$ROOT/build/design-audit/app"
  "$LSREG" -gc 2>/dev/null
}

if [[ " $WHAT " == *" mac "* ]]; then
  mac_copy
  for accent in ${ACCENTS:-none 0090FF}; do for mode in ${MODES:-light dark}; do
    D=$(mktemp -d "$TMP/mac.XXXX"); mkdir -p "$OUT/mac/$accent"
    env BAUD_DEMO=1 BAUD_DEMO_EVENTS=${EVENTS:-400} BAUD_NAME="${ME:-Robin}" BAUD_DIR="$D" BAUD_ACCENT=$accent BAUD_APPEARANCE=$mode \
      BAUD_PORTMAP=0 BAUD_RELAY=0 BAUD_HIDDEN=1 BAUD_NOTIFY=log \
      BAUD_SHOTS="$OUT/mac/$accent" ${STEPS:+BAUD_SHOTS_STEPS=$STEPS} \
      "$APP/Contents/MacOS/baud" > "$OUT/mac/$accent-$mode.log" 2>&1
    grep -E "snap|rendered|error|fatal" "$OUT/mac/$accent-$mode.log" | cut -c1-140
    rm -rf "$D"
  done; done
  mac_clean
fi

if [[ " $WHAT " == *" ios "* ]]; then
  SIM=$(xcrun simctl list devices | grep "$SIM_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
  [ -z "$SIM" ] && SIM=$(xcrun simctl create "$SIM_NAME" "iPhone 17 Pro")
  # A fresh boot: a system alert left from an earlier run stays over every later launch.
  xcrun simctl shutdown "$SIM" 2>/dev/null; xcrun simctl boot "$SIM" 2>/dev/null; xcrun simctl bootstatus "$SIM" >/dev/null
  xcrun simctl status_bar "$SIM" override --time 9:41 --batteryLevel 100 --batteryState charged --wifiBars 3 2>/dev/null
  xcrun simctl uninstall "$SIM" sh.rubric.baud.ios 2>/dev/null; xcrun simctl install "$SIM" "$IOS_BUILD"
  # No permission prompts over the pictures; a park for "here".
  xcrun simctl privacy "$SIM" grant location sh.rubric.baud.ios 2>/dev/null
  xcrun simctl privacy "$SIM" grant location-always sh.rubric.baud.ios 2>/dev/null
  xcrun simctl location "$SIM" set 40.7812,-73.9665 2>/dev/null
  # One store for the whole run, made once (the demo takes a while the first time); live places
  # get a store of their own, since a share left on asks for the location at every launch.
  D=$(mktemp -d "$TMP/ios.XXXX"); P=$(mktemp -d "$TMP/places.XXXX")
  snap() { xcrun simctl io "$SIM" screenshot "$OUT/ios/$accent/$1$suffix.png" >/dev/null 2>&1 && echo "ios $accent $1$suffix"; }
  launch() { # name, then env pairs
    local name=$1; shift
    xcrun simctl terminate "$SIM" sh.rubric.baud.ios 2>/dev/null
    env SIMCTL_CHILD_BAUD_DEMO=1 SIMCTL_CHILD_BAUD_DEMO_EVENTS=${EVENTS:-400} SIMCTL_CHILD_BAUD_NAME="${ME:-Robin}" \
      SIMCTL_CHILD_BAUD_DIR="${STORE:-$D}" SIMCTL_CHILD_BAUD_NOTIFY=log SIMCTL_CHILD_BAUD_ACCENT=$accent "$@" \
      xcrun simctl launch "$SIM" sh.rubric.baud.ios >/dev/null
    sleep ${WAIT:-5}
    snap "$name"
  }
  # First run: nobody named yet, a store nobody has used.
  fresh() {
    local F; F=$(mktemp -d "$TMP/fresh.XXXX")
    xcrun simctl terminate "$SIM" sh.rubric.baud.ios 2>/dev/null
    env SIMCTL_CHILD_BAUD_DIR="$F" SIMCTL_CHILD_BAUD_NOTIFY=log SIMCTL_CHILD_BAUD_ACCENT=$accent SIMCTL_CHILD_BAUD_CRATE=0 \
      xcrun simctl launch "$SIM" sh.rubric.baud.ios >/dev/null
    sleep 6; snap onboarding; rm -rf "$F"
  }
  first=1
  for accent in ${ACCENTS:-none 0090FF}; do for mode in ${MODES:-light dark}; do
    xcrun simctl ui "$SIM" appearance $mode
    suffix=$([ $mode = dark ] && echo -dark || echo "")
    mkdir -p "$OUT/ios/$accent"
    if [ $first = 1 ]; then
      launch warmup; WAIT=20 launch warmup
      STORE=$P launch warmup SIMCTL_CHILD_BAUD_DEMO_PLACES=1; STORE=$P WAIT=20 launch warmup SIMCTL_CHILD_BAUD_DEMO_PLACES=1
      rm -f "$OUT/ios/$accent/warmup"*; first=0
    fi
    for s in ${SCREENS:-chats Sam:chats weekend:chats hike:chats info:Sam info:weekend person:weekend add:weekend you status door locate:Sam onboarding places:Ana}; do
      case $s in
        info:*) launch "info-${s#info:}" SIMCTL_CHILD_BAUD_OPEN=${s#info:} SIMCTL_CHILD_BAUD_INFO=1 ;;
        person:*) WAIT=6 launch "person-${s#person:}" SIMCTL_CHILD_BAUD_OPEN=${s#person:} SIMCTL_CHILD_BAUD_INFO=person:Ana ;;
        add:*) WAIT=6 launch "add-${s#add:}" SIMCTL_CHILD_BAUD_OPEN=${s#add:} SIMCTL_CHILD_BAUD_INFO=add ;;
        locate:*) launch "locate" SIMCTL_CHILD_BAUD_OPEN=${s#locate:} SIMCTL_CHILD_BAUD_LOCATE=1 ;;
        places:*) STORE=$P launch "places-${s#places:}" SIMCTL_CHILD_BAUD_OPEN=${s#places:} SIMCTL_CHILD_BAUD_DEMO_PLACES=1 ;;
        door) WAIT=6 launch door SIMCTL_CHILD_BAUD_DOOR=friend ;;
        onboarding) fresh ;;
        you) launch you SIMCTL_CHILD_BAUD_TAB=you ;;
        status) launch status SIMCTL_CHILD_BAUD_STATUS_SHEET=1 ;;
        *:*) launch "${s%%:*}" SIMCTL_CHILD_BAUD_TAB=${s#*:} SIMCTL_CHILD_BAUD_OPEN=${s%%:*} ;;
        *) launch "$s" SIMCTL_CHILD_BAUD_TAB=$s ;;
      esac
    done
  done; done
  xcrun simctl terminate "$SIM" sh.rubric.baud.ios 2>/dev/null
  rm -rf "$D" "$P"
fi

if [[ " $WHAT " == *" calls "* ]]; then
  # The call screen draws every state offscreen and quits; on the Mac copy (it's always dark).
  mac_copy
  for accent in ${ACCENTS:-none 0090FF}; do
    D=$(mktemp -d "$TMP/call.XXXX"); mkdir -p "$OUT/calls/$accent"
    env BAUD_DEMO=1 BAUD_NAME="${ME:-Robin}" BAUD_DIR="$D" BAUD_ACCENT=$accent BAUD_PORTMAP=0 BAUD_RELAY=0 BAUD_HIDDEN=1 BAUD_NOTIFY=log \
      BAUD_CALL_SHOTS="$OUT/calls/$accent" "$APP/Contents/MacOS/baud" > "$OUT/calls/$accent.log" 2>&1
    grep -E "call shots|error" "$OUT/calls/$accent.log" | cut -c1-140
    rm -rf "$D"
  done
  mac_clean
fi
echo "pictures in $OUT"
