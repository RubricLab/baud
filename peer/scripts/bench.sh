#!/bin/sh
# The latency table: this machine against a remote one over ssh (an always-on machine you own).
# Builds peer-node, copies it to ~/peer-bench/peer-node on the remote, runs `peer-node bench`
# with fresh scratch nodes on both ends (nothing else on the remote is touched), prints the table
# and appends it with the commit and date to target/bench.md.
#
#   scripts/bench.sh --remote host [--note "what changed"] [bench flags: --only cold,relayed --runs 5 …]
#   (or BENCH_REMOTE=host)
#
# Scenarios: cold (open, open → online, dial known device), message, wake, relaunch, blob,
# ipchange (toggles this Mac's Wi-Fi), relayed. `peer-node bench --help` for the rest.
set -eu
cd "$(dirname "$0")/.."
remote="${BENCH_REMOTE:-}"
note=""
while [ $# -gt 0 ]; do
  case "$1" in
    --remote) remote="$2"; shift 2 ;;
    --note) note="$2"; shift 2 ;;
    *) break ;;
  esac
done
[ -n "$remote" ] || { echo "scripts/bench.sh: --remote <ssh host> (or BENCH_REMOTE) is required" >&2; exit 2; }
# The label is the tree the binary is built from, taken before the run.
rev="$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- peer peer-node || echo '+dirty')"
cargo build --release -p peer-node
ssh "$remote" 'mkdir -p ~/peer-bench'
scp -q target/release/peer-node "$remote:peer-bench/peer-node.new"
ssh "$remote" 'mv ~/peer-bench/peer-node.new ~/peer-bench/peer-node'
# Stale UPnP mappings from earlier runs fill the remote's router until it grants none (see the script).
scp -q scripts/upnp-prune.py "$remote:peer-bench/upnp-prune.py"
ssh "$remote" 'python3 -I ~/peer-bench/upnp-prune.py' | tail -1 || true
python3 -I scripts/upnp-prune.py 2>/dev/null | tail -1 || true
before="$(ssh "$remote" 'python3 -I ~/peer-bench/upnp-prune.py --count' 2>/dev/null || echo '?')"
# This machine too, when it sits behind a UPnP gateway of its own (at home it is the same router).
lbefore="$(python3 -I scripts/upnp-prune.py --count 2>/dev/null || echo '?')"
out="$(mktemp -t peer-bench)"
status=0
target/release/peer-node bench --remote "$remote" --out "$out" "$@" || status=$?
# Every node of the run has quit (or was killed and started again on its port): the router must
# hold no more of our entries for the remote than before. Then prune whatever a run still left.
after="$(ssh "$remote" 'python3 -I ~/peer-bench/upnp-prune.py --count' 2>/dev/null || echo '?')"
lafter="$(python3 -I scripts/upnp-prune.py --count 2>/dev/null || echo '?')"
held() { [ "$2" = "$1" ] || { [ "$2" != "?" ] && [ "$1" != "?" ] && [ "$2" -le "$1" ]; }; }
if held "$before" "$after" && held "$lbefore" "$lafter"; then verdict=pass; else verdict=FAIL; fi
printf '\nUPnP entries of ours on the gateway: %s %s before the run, %s after; %s %s before, %s after (%s).\n' "$remote" "$before" "$after" "$(hostname -s)" "$lbefore" "$lafter" "$verdict" >> "$out"
if [ "$verdict" = FAIL ]; then
  # Which entries a node left behind, before the prune below deletes them.
  ssh "$remote" 'python3 -I ~/peer-bench/upnp-prune.py --list' 2>/dev/null | grep -E ' (peer|iroh-portmap)$' | sed "s/^/  left on $remote: /" >> "$out" || true
fi
ssh "$remote" 'python3 -I ~/peer-bench/upnp-prune.py' | tail -1 || true
python3 -I scripts/upnp-prune.py 2>/dev/null | tail -1 || true
{
  echo
  echo "## $(date '+%Y-%m-%d %H:%M') · $rev · $(hostname -s) ↔ $remote${note:+ · $note}"
  echo
  cat "$out"
} | tee -a target/bench.md
rm -f "$out"
exit $status
