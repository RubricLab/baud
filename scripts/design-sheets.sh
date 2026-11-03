#!/bin/bash
# Contact sheets of the design pictures: the main screens of one set side by side, labelled, for a
# quick look. `scripts/design-sheets.sh build/design-audit/before` writes `<set>/sheet-*.png`.
# With two sets, `scripts/design-sheets.sh before after` puts each screen's two pictures together.
# `ROUND=2` picks round 2's screens. In a list, `old=new` pairs a screen that was renamed, and a
# screen new in the set after is paired with a blank marked "new".
set -u
cd "$(dirname "$0")/.."
A=${1:?a set of pictures}; B=${2:-}
if [ "${ROUND:-1}" = 2 ]; then
  mac="0090FF/mac-dm none/mac-dm-dark 0090FF/mac-members none/mac-hike 0090FF/mac-palette-1 0090FF/mac-emoji-1
    0090FF/mac-settings-page=0090FF/mac-settings-you 0090FF/mac-settings-page-dark=0090FF/mac-settings-updates-dark
    none/mac-settings-page=none/mac-settings-devices none/mac-settings-page=none/mac-friends
    none/mac-connection 0090FF/mac-msginfo-mine none/mac-msginfo-theirs-dark none/mac-open-weekend"
  ios="none/chats 0090FF/chats-dark none/Sam 0090FF/Sam-dark none/info-Sam none/info-weekend none/person-weekend
    none/you none/you=none/you-devices none/you=none/you-updates none/you=none/colour 0090FF/you-dark=0090FF/colour-dark
    none/status none/friends-map 0090FF/friends-map-dark none/hold-Sam 0090FF/hold-Sam-dark none/picker-Sam none/msginfo-Sam none/thread-weekend none/places-Ana"
else
  mac="0090FF/mac-dm 0090FF/mac-members none/mac-hike none/mac-home-dark 0090FF/mac-palette-1 0090FF/mac-newgroup-1 0090FF/mac-settings-page none/mac-files-dark"
  ios="none/chats none/Sam none/info-Sam none/info-weekend none/person-weekend none/add-weekend none/you 0090FF/chats-dark 0090FF/Sam-dark 0090FF/info-weekend-dark none/locate none/door"
fi
calls="0090FF/call-voice 0090FF/call-incoming 0090FF/call-video 0090FF/call-group-voice-3 none/call-mini-voice none/call-panel"
blank=$(mktemp -d)/new.png
magick -size 600x400 xc:'#e8e8e8' -font /System/Library/Fonts/Supplemental/Arial.ttf -pointsize 36 -fill '#888' -gravity center -annotate 0 'new' "$blank" 2>/dev/null \
  || convert -size 600x400 xc:'#e8e8e8' "$blank"
sheet() { # out, height, then pairs of label and file
  local out=$1 h=$2; shift 2
  local args=()
  while [ $# -ge 2 ]; do [ -f "$2" ] && args+=(-label "$1" "$2"); shift 2; done
  [ ${#args[@]} -eq 0 ] && return
  montage "${args[@]}" -geometry "x$h+12+12" -tile ${TILE:-4x} -background '#e8e8e8' -font /System/Library/Fonts/Supplemental/Arial.ttf -pointsize 18 "$out" && echo "$out"
}
for kind in mac ios calls; do
  list=${!kind}; h=$([ $kind = ios ] && echo 900 || echo 640)
  pairs=()
  for s in $list; do
    old=${s%%=*}; new=${s#*=}
    if [ -n "$B" ]; then
      [ -f "$B/$kind/$new.png" ] || continue
      before="$A/$kind/$old.png"; [ -f "$before" ] || before=$blank
      pairs+=("before $old" "$before" "after $new" "$B/$kind/$new.png")
    else pairs+=("$new" "$A/$kind/$new.png"); fi
  done
  out=$([ -n "$B" ] && echo "$B/compare-$kind.png" || echo "$A/sheet-$kind.png")
  TILE=$([ -n "$B" ] && echo 4x || ([ $kind = ios ] && echo 6x || echo 4x)) sheet "$out" $h ${pairs[@]+"${pairs[@]}"}
done
rm -rf "$(dirname "$blank")"
