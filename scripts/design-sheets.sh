#!/bin/bash
# Contact sheets of the design pictures: the main screens of one set side by side, labelled, for a
# quick look. `scripts/design-sheets.sh build/design-audit/before` writes `<set>/sheet-*.png`.
# With two sets, `scripts/design-sheets.sh before after` puts each screen's two pictures together.
set -u
cd "$(dirname "$0")/.."
A=${1:?a set of pictures}; B=${2:-}
mac="0090FF/mac-dm 0090FF/mac-members none/mac-hike none/mac-home-dark 0090FF/mac-palette-1 0090FF/mac-newgroup-1 0090FF/mac-settings-page none/mac-files-dark"
ios="none/chats none/Sam none/info-Sam none/info-weekend none/person-weekend none/add-weekend none/you 0090FF/chats-dark 0090FF/Sam-dark 0090FF/info-weekend-dark none/locate none/door"
calls="0090FF/call-voice 0090FF/call-incoming 0090FF/call-video 0090FF/call-group-voice-3 none/call-mini-voice none/call-panel"
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
    if [ -n "$B" ]; then pairs+=("before $s" "$A/$kind/$s.png" "after $s" "$B/$kind/$s.png")
    else pairs+=("$s" "$A/$kind/$s.png"); fi
  done
  out=$([ -n "$B" ] && echo "$B/compare-$kind.png" || echo "$A/sheet-$kind.png")
  TILE=$([ -n "$B" ] && echo 4x || ([ $kind = ios ] && echo 6x || echo 4x)) sheet "$out" $h "${pairs[@]}"
done
