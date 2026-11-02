#!/bin/bash
# Run 2: a Rust device invites, the Mac app redeems and sends text and a photo; the person's other
# Rust device is away meanwhile and receives it carried when it returns; Rust answers the Mac.
S=${BAUD_LAB:?a scratch dir with tools/lab.sh, core-lab/BaudLab.app (a lab copy of the Mac app) and core-lab/*-photo.jpg}
L=$S/core-lab/run2; rm -rf $L; mkdir -p $L
B="$(cd "$(dirname "$0")/../.." && pwd)/target/debug/baud"
APP=$S/core-lab/BaudLab.app
LAB=$S/tools/lab.sh
$B --dir $L/ben --name Ben --device "Ben's phone" "link-file $L/devlink" "wait-devices 2 60" "sleep 1" > $L/ben.log 2>&1 &
BEN=$!
$B --dir $L/ben2 --device "Ben's tablet" "join-file $L/devlink 60" "sleep 3" "invite-file $L/maclink" "wait-contact Max 120" "wait-chat Max 60" \
  "wait-text Max 90 hello rust from mac" "fetch-all Max 60" "send Max got it, from rust" "wait-delivered Max 60 got it, from rust" "stay 40" "status" > $L/ben2.log 2>&1 &
BEN2=$!
wait $BEN; echo "ben away"
"$LAB" "$APP" BAUD_DIR=$L/mac BAUD_NAME=Max BAUD_JOURNEY=guest BAUD_LINK_FILE=$L/maclink BAUD_SAY="hello rust from mac" BAUD_SEND_FILE=$S/core-lab/mac-photo.jpg BAUD_LOG_FILE=$L/mac.log > $L/mac.out 2>&1 &
M=$!
for i in $(seq 120); do grep -q "got it, from rust" $L/ben2.log 2>/dev/null && grep -q "hash ok" $L/ben2.log && break; sleep 1; done
sleep 3
$B --dir $L/ben "wait-chat Max 60" "wait-text Max 60 hello rust from mac" "fetch-all Max 60" "status" > $L/ben-back.log 2>&1
echo "ben back exit $?"
sleep 2
kill $M; wait $M 2>/dev/null; kill $BEN2; wait $BEN2 2>/dev/null
echo "--- ben"; grep -v " step " $L/ben.log | cut -c1-200
echo "--- ben2"; grep -v " step " $L/ben2.log | cut -c1-230
echo "--- ben back"; grep -v " step " $L/ben-back.log | cut -c1-230
echo "--- mac"; grep -E "guest|journey|file|crate" $L/mac.log | grep -v "peers:" | cut -c1-260 | head -40
