# The four journeys, reproduced

Every command below runs from the `peer/` folder of this repo after `cargo build --release -p peer-node`; set `PN=target/release/peer-node`. Each node is one terminal; `run` prints events as they happen and takes commands on stdin. `--no-nearby` is only because the nodes share one Mac. The in-process versions are `cargo test`: `journey.rs`, `inbox.rs`, `blobs.rs`, `groups.rs`, `probe.rs`.

## 1. Address book (invite, add, rename, link a device, revoke)

```
$PN --dir /tmp/pa run --name ana --invite --link-device --auto-confirm-links --no-nearby   # prints an invite and a device link
$PN --dir /tmp/pb run --name sam --no-nearby --add '<invite link>'                           # "added ana" · "online ana's … direct 0 ms"
$PN --dir /tmp/pc run --no-nearby --link '<device link>'                                     # "linked: now ana", the book replicates, it dials sam
```
In ana's terminal: `name Ana` (sam prints the new card within a second; his petname for her stays his), `contacts`, `peers`, `status`.

## 2. Relaying (a pair that can't punch connects through a helper, named)

On an always-on machine with a mapped port:
```
$PN --dir ~/peer-relay run --port 4101 --relay --auto-confirm-links --no-nearby   # "relaying for cardholders at http://<public>:<port>/ http://<lan>:4101/"
```
`invite` twice on it. Two devices that cannot reach each other (a laptop behind a symmetric NAT and an unmapped box behind a home NAT):
```
$PN --dir /tmp/L  run --name laptop --no-nearby --no-vpn --add '<relay invite 1>'
$PN --dir /tmp/M2 run --name box    --no-nearby --no-portmap --add '<relay invite 2>'
```
`invite` on the laptop, `add <link>` on the box: both print `online … relayed by <relay device> NN ms`. Measured between a laptop behind an office network's symmetric NAT and an always-on machine at home: 18 to 30 ms.

## 3. Inboxing (offline recipient, carried by a named device)

```
$PN --dir /tmp/ja run --name ana --no-nearby    # ana: `invite` twice
$PN --dir /tmp/js run --name sam --no-nearby    # sam: `add <ana link 1>`, `invite`
$PN --dir /tmp/jj run --name jo  --no-nearby    # jo:  `add <ana link 2>`, `add <sam link>`
```
sam: `quit`. ana: `post sam hello while you are away` → "held, carriers will get it"; jo: `status` → "helping: 1 envelopes". ana: `quit`.
`$PN --dir /tmp/js run --no-nearby` → "inbox …: "hello while you are away" (carried by jo's …)". `$PN --dir /tmp/ja run --no-nearby` → "delivered …".

## 4. Syncing (a 100 MB blob, paused and resumed)

```
head -c 104857600 /dev/urandom > /tmp/big.bin
$PN --dir /tmp/ba run --name ana --no-nearby    # ana: `invite`, `blob-add /tmp/big.bin` → "blob <hash>"
$PN --dir /tmp/bs run --name sam --no-nearby    # sam: `add <link>`, `fetch ana <hash> /tmp/copy.bin`, `pause`, `transfers`, `resume`, `transfers`
```
`Paused N / 0 bytes` twice, then `Done 104857600 / 104857600`; `shasum -a 256 /tmp/big.bin /tmp/copy.bin` agree.

## The release gate

```
$PN gate --minutes 10              # rootless: nettop/ss socket inventory; PASS when nothing points off-peer
sudo $PN gate --minutes 10 --capture   # adds the tcpdump proof of every destination
```
