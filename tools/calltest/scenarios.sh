#!/bin/sh
# The calltest yardstick: five paths, one call each, the summaries side by side.
# `scenarios.sh out-dir [ana-engine] [bo-engine]`, engines "new" (default) or "0.2.15".
# Builds first; run it with nothing else heavy on the machine, since timing is what it measures.
set -e
cd "$(dirname "$0")"
out=${1:?out dir}
export CALLTEST_ANA=${2:-new} CALLTEST_BO=${3:-new}
mkdir -p "$out"
swift build -c release >/dev/null
run() {
	name=$1; secs=$2; shape=$3
	echo "== $name ($CALLTEST_ANA ← → $CALLTEST_BO)"
	if [ -n "$shape" ]; then CALLTEST_SHAPE=$shape .build/release/calltest "$secs" > "$out/$name.txt" 2>&1
	else env -u CALLTEST_SHAPE .build/release/calltest "$secs" > "$out/$name.txt" 2>&1; fi
	sed -n '/^Bo→Ana \[/,$p' "$out/$name.txt"
}
run loopback 30 ""
run 3mbit-40ms-1pct 30 "rate=3mbit,delay=40ms,loss=1%,queue=150ms"
run 20mbit-20ms 30 "rate=20mbit,delay=20ms,queue=150ms"
run step-10-to-2mbit 40 "rate=10mbit,delay=20ms,queue=150ms,step=20s:2mbit"
run 5pct-loss 30 "rate=20mbit,delay=20ms,loss=5%,queue=150ms"
