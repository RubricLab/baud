# baud-core's API (Kotlin)

`Baud` is `CoreSurface` (BaudCore/Surface.swift) over Rust: the same calls, the same `Change`s,
the same wire as the iPhone and Mac apps, minus spaces, channels and calls. The bindings are
`bindings/kotlin/sh/rubric/baud/ffi/baud.kt` (package `sh.rubric.baud.ffi`), generated from the
library by `scripts/bindings.sh`; the library is `libbaud_ffi.so`, built for `arm64-v8a` by
`scripts/build-android.sh` into `apps/android/app/src/main/jniLibs/arm64-v8a/`.

## Wiring it in

- Gradle: `implementation("net.java.dev.jna:jna:5.15.0@aar")` (uniffi's Kotlin calls through JNA),
  and `kotlinx-coroutines` (async calls are `suspend`). Copy `baud.kt` into the source set, or add
  `core/bindings/kotlin` as a source dir.
- Proguard (release): `-keep class com.sun.jna.** { *; }` and `-keep class sh.rubric.baud.ffi.** { *; }`.
- Nothing else to load: the first call loads `libbaud_ffi.so`.

## Opening

```kotlin
val baud = Baud.open(
    dir = context.filesDir.resolve("baud").path,   // the store, blobs and peer's files
    keychain = AppKeys(context),                      // you implement Keychain: get/put/delete small secrets
    config = Config(name = "", deviceName = Build.MODEL, deviceKind = DeviceKind.ANDROID),
)                                                     // suspend; under a second, network comes up behind it
val sub = baud.subscribe(object : Listener {
    override fun onChange(change: Change) { /* hop to main, re-read what changed */ }
})
baud.setOnline(true)                                  // in front; false when backgrounded
```

Open once per process and keep it. `Keychain` items are opaque names (`peer-device`, `peer-user`, …);
store them encrypted (Android Keystore), readable after first unlock. Throwing from `get` means
"couldn't read", returning null means "not there".

`Config` switches for labs and tests only: `portmap = false` never asks the router for a port,
`nearby = false` announces nothing on the LAN, `vpn`, `relay`, `public`.

## Calls

Every call is on the caller's thread and returns in milliseconds (SQLite on the device), except the
`suspend` ones: `Baud.open`, `add`, `link`, `blob`, `shutdown`, `reset`. Failures throw
`BaudException` subclasses whose `message` is the sentence to show: `NotFound`, `Expired`, `Used`,
`BadLink`, `NotAdmin`, `NotMember`, `Refused`, `Offline`, `Unreachable`, `Store`, `Failed`.

| CoreSurface | Kotlin |
|---|---|
| `me()`, `setName`, `setAvatar(path)` | `me()`, `setName(name)`, `setAvatar(path)` |
| `linkDevice()`, `link(link)`, `revoke(device)` | `linkDevice(): Link`, `suspend link(url)`, `joiningCode(url)`, `confirmLink(req, accept)`, `revoke(device)` |
| `invite()`, `add(link)`, `contacts()`, `verify` | `invite(): Link`, `suspend add(url): Contact` (a friend link, or a reply to mine), `reply(url): Link`, `contacts()`, `verify(user, fingerprint)`, `unfriend(user)` |
| `conversations(kind)`, `conversation(id)` | `conversations(kind: Kind?)`, `conversation(id)`, `notes()` (my chat with myself), `delete(conv)` |
| `events(conv, before, limit)`, `thread(…)` | `events(conv, before, limit)`, `thread(conv, root, before, limit)` |
| `send(conv, draft)` | `send(conv, Draft(text, attachments = listOf(path), reply, thread, mentions)): Event` |
| `react`, `edit`, `redact`, `pin`, `markRead` | the same names |
| `typing(conv)`, `typingNow(conv)` | the same |
| `members`, `addMember`, `removeMember`, `leave`, `setName(conv)`, `setTopic` | `members`, `addMember`, `removeMember`, `leave`, `rename(conv, name)`, `setTopic` |
| `delivery(conv, event)` | `delivery(conv, event): Delivery` (per device, plus `sentence` and `best`) |
| `createChat(users)`, `createGroup(name, users)` | the same |
| `search(query, scope)` | `search(query, conv?)` |
| `blob(hash, key)` | `suspend blob(hash, key): String` (a file path) |
| `peers()`, `carrying()`, `setOnline` | the same, plus `netState()`, `networkChanged()`, `trace()`, `canWake(device)` |
| (closing) | `suspend shutdown()` lets go of the network; `close()` (AutoCloseable) frees the object |
| `subscribe(listener)` | `subscribe(Listener): Subscription` (`cancel()` to stop) |
| profile (the colour) | `setProfile(key, value)`, `profile(key)` |

`parseLink(text): Link?` (top level) reads a pasted code, a `baud://` or `https://baud.rubric.sh/`
link without the core: kind, whose, expiry. `version()` names the core and peer.

## Changes

`Change` is ids only; re-read what it names. The SPEC's cases plus the ones the Swift adapter
had as callbacks:

- `Me`, `Contacts`, `Conversations`, `Peers`, `Carrying`
- `Conversation(id)`: its timeline changed; `Delivery(conv)`: a delivery line under it; `Typing(conv)`
- `LinkRequest(req, code, device, name, kind)`: a device asks to become mine; show the six digits,
  then `confirmLink(req, true|false)`
- `Reached(device)`: a link being redeemed here reached its meeting device
- `Removed`: another of my devices removed this one; say so, then `reset()`
- `Network`: re-read `netState()`
- `Places(conv)`: someone's place in that chat changed, or my share in it did: re-read `places(conv)`
- `Replied(user)`: a reply I made was opened by its link's maker; we met (`Contacts` comes too)
- `ReplyLapsed(user)`: a reply I made stopped waiting unopened

Listeners are called on the core's threads; never block in one.

## Types

Records are `data class`es, enums `enum class` or `sealed class` (Kotlin names: `DeviceKind.ANDROID`,
`Path.Direct(ms)`, `Path.NotConnected`, `DeliveryState.Carried(by)`). Every time is unix
milliseconds (`Long`). Sentences the Swift apps build in `Sentences.swift` come ready-made where
the UI shows them: `Device.sentence`, `Contact.sentence`, `Peer.sentence`, `Delivery.sentence`,
`Carrying.sentence`. `Event.kind` is the event type (`MESSAGE`, `MEMBER`, `STATE`, `CREATE`; the
timeline only carries those); `system` is the line for non-messages.

## Files

`send` with attachments copies each file into the core's store and hashes it there (SHA-256),
so call it off the main thread (`Dispatchers.IO`) when files are big. The original goes, as on
the Apple apps: no re-encoding, no downscale. Files up to 50 MB come to every device with their
message; bigger ones when someone opens them (`blob`). `Attachment.width/height` are read for
JPEG (EXIF orientation applied), PNG, GIF, WebP and HEIC. Drawing a 12 MP photo is the app's:
decode it downscaled (`ImageDecoder` with `setTargetSize`, or `inSampleSize`), as the Apple
apps draw a 1000 px thumbnail.

## Replies

A friend link whose maker can't be reached from here gets an answer: `reply(url)` makes a reply
link (`LinkKind.REPLY`) for the maker to open or scan, while this device keeps dialing theirs.
`Change.Replied(user)` when they open it (we're friends), `ReplyLapsed(user)` if it runs out.
`reply` throws BadLink (not a friend link), Expired, Used (already a friend). The maker opens a
reply with `add(url)`, as an inviter: the chat is made on that side. Its errors: Expired, NotFound
(it answers a link from another of my devices), Used (my link went to someone else), Unreachable;
opened again, it returns the contact.

## Places

Location sharing per chat, as the Apple apps do it (`Places.swift`). `sharePlace(conv, until)`
(unix ms, or null: until I stop), `stopSharing(conv)`, `sharing(): List<Share>`. While
`wantsPlace()` is true, run the location service and call `moved(lat, lon, accuracy)` with each
fix (the app throttles: 25 m or 20 s). `places(conv): List<Place>` is everyone sharing with me in
that chat, newest first; a share whose `until` has passed is gone (re-read it on a timer for the
"2 min ago" line). A fix goes straight to the chat's online devices, sealed with the chat's key,
never to carriers or a server; a device that comes online gets my latest at once.

## Waking iPhones

An iPhone hands every device it connects to a wake ticket (its push addresses sealed to the wake
relay, https://wake.baud.rubric.sh). The core keeps them, and when a message someone else wrote
can't reach that iPhone live, it asks the relay to wake it (at most every 20 s per device; never
for my own messages syncing to my own devices). Nothing to do in the app; `canWake(device)` says
whether this phone could. Android mints no tickets: it keeps its own service running.

## Lifecycle

`shutdown()` lets go of the network; the object still reads its store, and anything written
after it waits in the store. Open the same `dir` again (a new `Baud`) to go on: the clocks
send what the other side lacks, so nothing written is lost across stop/start or process death.
One open `Baud` per `dir` at a time: shut the old one down before opening again.

## Building

baud-core builds on `../peer`, the network layer in this repo. `scripts/build-android.sh` builds
`libbaud_ffi.so` for the phone and regenerates these bindings; it needs rustup, `cargo-ndk` and the
Android NDK.

## Stability

Changed once: `close()` became `shutdown()` (the generated `AutoCloseable.close()` clashed with it).

Additive changes only from here: new calls, new fields with defaults, new `Change` cases (keep a
`else ->` branch). A breaking change is announced first.
