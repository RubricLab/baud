# Working on baud

How the repo fits together, the switches the apps read at launch, and the scripts that build,
test and ship. The [README](../README.md) has the short version of the build.

## How the pieces fit

```text
apps/mac, apps/ios ── apps/shared ── BaudCore (Swift) ──┐
                                                         ├── peer (Rust, on iroh)
apps/android ─────────────── core/baud-ffi ── baud-core ┘
```

- **`peer/`** is the network, and the only code that touches iroh. It knows devices, people,
  cards, links, address records, relays and envelopes, and carries opaque bytes. The Apple apps
  reach it through `peer/swift/PeerKit` (UniFFI bindings made by `peer/scripts/build-swift.sh`);
  `apps/shared/Crate.swift` is the only Swift file that names its types.
- **`BaudCore/`** is baud on one device for the Apple apps: conversations, feeds in SQLite with
  FTS5 search, sealing, delivery as rows, and a `Transport` seam that `apps/shared/Baud.swift`
  fills with peer. `CoreSurface` (`Surface.swift`) is everything a view may ask.
- **`core/`** is the same layer in Rust (`baud-core`), exposed to Kotlin by `baud-ffi`. Golden
  vectors in `core/vectors` keep the two byte-compatible; `BaudCore`'s `VectorTests` and
  `core/baud-core/tests/vectors.rs` both check them. [`core/API.md`](../core/API.md) is its
  Kotlin API.
- **`wake/`** is the wake relay. `wake/src/ticket.rs` spells out a ticket's bytes, and its tests
  open `wake/tests/swift-ticket.json`, a ticket the Swift code minted (`BAUD_WAKE_VECTOR=<path>
  swift test` in `BaudCore` writes a fresh one).

A few rules hold the apps together:

- **No protocol logic in views.** Views read `CoreSurface` and draw rows.
- **Every delivery state is data.** The line under a message (sent, carried by a device,
  delivered, read) is built from receipts and `handed` rows, nowhere else.
- **Status is a sentence.** `Sentences.swift` (and `core/baud-core/src/sentences.rs`) make every
  word the apps show about paths, devices and delivery.

## Launch switches

Environment variables the apps read at launch. On the simulator, prefix them with
`SIMCTL_CHILD_`. Spaces (Slack-like channels) are built but hidden: compile with the `BAUD_SPACES`
flag (`SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) BAUD_SPACES'`) to show them.

| Switch | Effect |
| --- | --- |
| `BAUD_DEMO=1` | Three demo people (Ana with a Mac and an iPhone, Jo, Sam) on an in-process mesh, with chats, a group and a space. Every delivery state on screen is computed, not painted. Runs without the network. |
| `BAUD_DEMO_EVENTS=10000` | How many events the demo's busiest channel gets. |
| `BAUD_DEMO_PLACES=1` | Ana and Jo share where they are, for pictures. |
| `BAUD_DEMO_DISAPPEAR=86400` | Disappearing messages on (that many seconds) in my chat with Sam and in Ana's with me, a line after each, for pictures. |
| `BAUD_CRATE=0` | Run on the in-process stub alone, without peer. |
| `BAUD_DIR=path` | Keep the store somewhere else. Use one per copy of the app you run side by side. |
| `BAUD_NAME=…` | Skip the name screen. |
| `BAUD_ACCENT=0090FF` or `none` | The colour. |
| `BAUD_PORTMAP=0`, `BAUD_RELAY=0` | No router port mapping, no relaying for others. Use these for test copies. |
| `BAUD_WAKE_URL=…` | A different wake relay. |
| `BAUD_MEASURE=1` | Print cold open, keypress-to-frame and scroll fps to stderr, then quit. |
| `BAUD_SHOTS=dir` | (Mac) Walk the screens and save every window into `dir`. `BAUD_SHOTS_STEPS=dm,home,…` picks screens, `BAUD_APPEARANCE=light` or `dark` the look. |
| `BAUD_TAB=spaces BAUD_OPEN=general` | (iPhone) Open a screen, for `simctl io screenshot`. |
| `BAUD_LOG_FILE=path` | Keep a copy of the log, for where stderr can't be read. |

The linking smoke drives two or three real processes with no clicks:

| Switch | Effect |
| --- | --- |
| `BAUD_JOURNEY=host` or `guest`, `BAUD_LINK_FILE=path` | The two-process meet-and-message proof. |
| `BAUD_NAME_LATE=Ana` | Type the name two seconds in. |
| `BAUD_DOOR=friend`, `device` or `paste` | Open that door once named. |
| `BAUD_OPEN_LINK=baud://…` | Launch as if a link was scanned or tapped. |
| `BAUD_AUTO_OPEN=1`, `BAUD_AUTO_ACCEPT=1` | Press the one button after a few seconds. |
| `BAUD_WINDOW=settings` | (Mac) Open that window at launch. |

## Scripts

| Script | What it does |
| --- | --- |
| `peer/scripts/build-swift.sh` | Builds peer for iOS, the simulator and macOS, and writes `peer/swift/PeerKit`. Run it after changing peer. |
| `core/scripts/build-android.sh` | Builds `libbaud_ffi.so` for Android and regenerates the Kotlin bindings. Gradle runs it for you. |
| `core/scripts/bindings.sh` | Regenerates the Kotlin bindings alone. |
| `scripts/icon.sh`, `scripts/icon-alternates.sh` | Render the app icon and the per-colour icons from `apps/icon`. |
| `apps/icon/devices/make.py` | Draws the device glyphs and writes their parts as Swift. |
| `scripts/ship-mac.sh` | Release build, Developer ID signing, notarization and a stapled DMG. Needs an Apple developer account. |
| `scripts/ship-ios.sh` | Archive and upload to TestFlight. |
| `apps/android/scripts/ship-android.sh` | The signed release APK and its checksum for `site/releases.json`. |
| `peer/lab/lab.py` | The network lab: real nodes behind emulated home, carrier and office routers in Docker. See [`peer/lab`](../peer/lab). |
| `peer/scripts/bench.sh` | Latency table between this machine and one you own, over ssh. |
| `tools/calltest/scenarios.sh` | Call quality across five network paths. |

## Running the wake relay

```sh
cd wake
cargo run -- keygen    # prints WAKE_KEYS=1:… and the public key to pin in the apps
WAKE_KEYS=… APNS_KEY="$(cat AuthKey_XXXX.p8)" APNS_KEY_ID=… APNS_TEAM_ID=… APNS_TOPIC=<bundle id> cargo run
```

The Dockerfile builds a static image with nothing else in it. The relay never logs a request, so
its only output is the line it prints at start.
