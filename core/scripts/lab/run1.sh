#!/bin/bash
# Run 1: the Mac app invites, a Rust device (with a second Rust device of the same person) redeems;
# Rust → Mac text and photo; then the Mac is away, Rust writes, its second device carries it, and
# the relaunched Mac receives it carried.
S=${BAUD_LAB:?a scratch dir with tools/lab.sh, core-lab/BaudLab.app (a lab copy of the Mac app) and core-lab/*-photo.jpg}
L=$S/core-lab/run1; rm -rf $L; mkdir -p $L
B="$(cd "$(dirname "$0")/../.." && pwd)/target/debug/baud"
APP=$S/core-lab/BaudLab.app
LAB=$S/tools/lab.sh
$B --dir $L/ana2 --device "Ana's tablet" "join-file $L/devlink 60" "stay 400" > $L/ana2.log 2>&1 &
A2=$!
$B --dir $L/ana --name Ana --device "Ana's phone" "link-file $L/devlink" "wait-devices 2 60" "add-file $L/maclink 120" "wait-chat Mia 60" \
  "send Mia hello mac from rust" "photo Mia $S/core-lab/rust-photo.jpg a photo from rust" "wait-delivered Mia 60 hello mac from rust" \
  "wait-offline Mia 300" "send Mia while you were away" "wait-carried Mia 60 while you were away" "status" > $L/ana.log 2>&1 &
A=$!
sleep 3
"$LAB" "$APP" BAUD_DIR=$L/mac BAUD_NAME=Mia BAUD_JOURNEY=host BAUD_LINK_FILE=$L/maclink BAUD_LOG_FILE=$L/mac.log > $L/mac.out 2>&1 &
M=$!
sleep 6; echo "keys in the lab dir: $(ls $L/mac/keys 2>/dev/null | tr '\n' ' ')"
for i in $(seq 150); do grep -q "hash ok" $L/mac.log 2>/dev/null && break; sleep 1; done
sleep 4
kill $M; wait $M 2>/dev/null; echo "mac 1 stopped"
wait $A; echo "ana exit $?"
"$LAB" "$APP" BAUD_DIR=$L/mac BAUD_NAME=Mia BAUD_JOURNEY=host BAUD_LINK_FILE=$L/maclink2 BAUD_LOG_FILE=$L/mac2.log > $L/mac2.out 2>&1 &
M=$!
for i in $(seq 120); do grep -q "while you were away" $L/mac2.log 2>/dev/null && break; sleep 1; done
sleep 4
kill $M; wait $M 2>/dev/null; kill $A2; wait $A2 2>/dev/null
echo "--- ana"; grep -v " step " $L/ana.log | cut -c1-230
echo "--- ana2"; grep -v " step " $L/ana2.log | cut -c1-200
echo "--- mac 1"; grep -E "host|journey|file|added|crate" $L/mac.log | grep -v "peers:" | cut -c1-260 | head -40
echo "--- mac 2"; grep -E "host .*:|file|crate" $L/mac2.log | grep -v "peers:\|contacts:" | cut -c1-260 | head -20
