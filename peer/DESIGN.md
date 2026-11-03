# peer: design

peer is the network layer under baud: a Rust library on iroh that lets people's devices find each other and talk directly, with no servers. This document says how the network is designed and why. `SPEC.md` is the API reference, `examples/README.md` reproduces the four outcomes by hand, and `lab/` measures the design against emulated routers.

## Why

Two people need to find each other with no server in the middle. Several apps met this problem separately, and their answers converged. peer keeps that answer in one Rust crate that an app embeds as a dependency and nothing else. It was written for baud and shaped so other apps (Rubric's darkroom and Computer among them) can embed the same crate.

The apps stay separate. Each is its own node with its own keys, its own friends, its own helpers and its own iroh endpoint. Nothing runs between them, nothing is shared at runtime, and uninstalling one changes nothing for the others. What is shared is the code, the vocabulary and the quality bar.

## Rules

1. **No cloud, ever.** No server of ours touches a key, an address, a message or a byte of traffic. No public relays, n0's included, in any release build. No DHT. No push service in the crate. No account. A release gate proves with a packet capture that, with no user action, a node sends nothing to any host that is not a peer it holds a card for. Two fetches are allowed: an app may ask its own download site for its signed release record when it opens, when it comes to the front, and when a person presses *check for updates*; and it may download the release that record names. A release is taken only when the record's signature, the download's hash and the app's own signature all check out. By default the app downloads and checks it by itself and puts it in place when the app next quits; a person can turn that off, and then the app shows "update available" and downloads nothing until they press the button. Nothing ever restarts on its own. Later, a signed release record can travel between peers as class small, so updates are learned from friends rather than from a site. Waking a sleeping iPhone needs Apple's push service, which only a server can reach, so baud does that outside the crate (`wake/` in this repository), through a relay that sees a sealed ticket and keeps nothing.
2. **Everything is hole punch.** Direct QUIC via iroh whenever the NATs allow. When they don't, a *helper* forwards ciphertext: your own devices first, then friends' devices that advertise they are reachable. Nothing else. No app ships a public relay, and no one-click cloud relay is offered anywhere.
3. **Your address lives only with people you chose.** Address records are sealed to each cardholder individually. Forwarders see which key a record is for and nothing else. Strangers see nothing because strangers can't connect: a node accepts a connection only from a device in a card it holds, or one holding a live invite secret. (Today records are signed and handed only to cardholders, but not yet sealed per recipient; see `SPEC.md`, "Finding, records, probe".)
4. **Keys are the address, petnames are the UI, groups are the only namespaces.** No canonical names, no registry. Each person names their friends. A group (a space, a group chat, a shared folder) carries its own member list mapping keys to names.
5. **Honest status in the UI.** Direct, relayed by whom, carried by whom, waiting, unreachable. Never a spinner where a sentence belongs. The status is a mark in front, with the sentence a tap away.

## Vocabulary

| | |
|---|---|
| **device** | one install. One iroh secret key in the keychain. Its public key is the only thing anyone dials. |
| **person** | a user key, copied to each linked device. Its fingerprint is the safety number. |
| **card** | `{ user, name, avatar, devices, revoked, seq }` signed by the user key. Never holds an address. |
| **contact** | a card you accepted by invite link or QR code. Always mutual. |
| **address record** | `{ device, addresses, relay, reachable, awake, tags, seq }` signed by the device key. Broadcast to cardholders on change, exchanged on connect, cached, dialed. Never published. |
| **envelope** | a sealed payload in transit: `{ to, expires, hops, ciphertext }`. Says who it is for, how big it is and until when, and nothing else. |
| **helper** | any online device, in three jobs at once: *cache* (holds friends' freshest records), *carrier* (holds envelopes for devices it can reach later), *relay* (only if `reachable`: tells a device its own public address, coordinates the hole punch between two devices that both hold a live connection to it, and forwards packets when the punch fails). Every device is a helper for everyone whose card it holds. Without a reachable helper, two devices behind ordinary home NATs cannot punch at all: iroh does its reflexive-address discovery and punch signaling through its relay protocol. So a helper is an embedded iroh relay server on a reachable device, and the `relay` field of an address record names a friend's or an own device, never a hosted URL. |
| **reachable** | two halves, carried separately in the record: `udp` (this device can be hole-punched to, behind a cone NAT or a UDP mapping, so it can be a direct target) and `tcp` (its relay port is mapped or public, so it can relay). Re-checked on every network change. A symmetric NAT sets both false. A home device is often `udp` without `tcp`. |
| **awake** | the app is open, as the app says with `set_online`. Broadcast on change. |

Three things the crate proved while being built are rules too. The probe is a `Bind` frame over an authenticated QUIC connection from iroh's own socket: no second socket, no unauthenticated responder. Admission is proven only by a round trip, so the crate completes one before it hands any app a connection; otherwise `NotInTheirBook` would look like a working connection. And each app uses its own keychain access group, never a shared one, because the apps are separate.

## Identity you can check

A person you did not add yourself (a co-member added by someone else) is shown with who introduced them and whether anyone you trust has checked them. Three states, nothing more:

- **verified by you**: you scanned or compared their safety number.
- **vouched by Ana, Jo**: people you verified have signed a statement that they verified this key.
- **unverified**.

A vouch is a signed statement `{ by, for, at, sig }` that the voucher keeps in their own card, so it travels with cards through groups and leaves a paper trail that cannot be forged or quietly removed. No scores, no transitive trust beyond one hop, no server. Vouches belong to the crate (`vouch(user)` after `verify`, and `trust(user) -> Verified | Vouched([users]) | Unverified`), and every app shows the state next to a name wherever a stranger can appear.

Built so far: `verify` and the "verified by you" state, and a contact that arrives by an identity redirect is marked as vouched by its old key (see "Identity redirect"). Signed vouches and `trust` are still to come.

## The network loop

The network is the foundation, and everything else is downstream of it. It needs to feel like a strong protocol: consistent delivery, and friends always telling each other their addresses. At the network level a device knows who is online. It broadcasts its address to all of its friends, always, and they pass it on when other people come online. Carrying and relaying bytes come after, once a device knows who is a mutual and who is online. Everything else is optimization. At base this is a simple protocol.

The loop, as rules the crate keeps running from `open` to `close`, on every device, with no app involvement:

1. **Mutuals are the set.** A mutual is a device whose card you hold and whose person holds yours: your own devices, your contacts' devices, and co-members of a group you are in (in a space; see "Three tiers" for chats). Nothing outside the set is dialed, answered or told anything.
2. **Always dialing.** For every mutual device with a record, a dial attempt is always either live or scheduled: backoff 1, 2, 4 … 60 s, reset to 1 s the moment a fresh record for it arrives, the network changes, or `set_online(true)` is called. Every address in the record is tried in parallel, direct first, then through any relay the record names, then through any own device that is connected. Beside it, the devices connected to me that also hold it are asked to introduce us: each tells it to dial me back at once and tells me where it sees it, so both NATs open toward each other (a hole punch through any mutual, `introduce`). A live connection is kept alive with a keepalive every 20 s on its selected path only, just under the shortest idle pinhole measured (a carrier's 30 s). Battery outranks presence latency, so a peer that vanishes without a word is noticed within a minute (40 to 60 s) and the dial schedule resumes. Failover does not wait on that: an unanswered send or handoff makes the device silent at once, and its messages go to carriers. A live call keeps its own 1 s keepalive and 4 s idle timeout.
3. **Online means connected.** A device is online to you exactly when you hold a live connection to it. The crate reports per device: online, path (direct, relayed by whom, nearby), RTT, record age, found by (cache, push, exchange, nearby, invite), last seen. There is no other definition of presence.
4. **Broadcast on change.** On every network change, every change of reachability, every `set_online(true)` and every new linked device: sign a fresh address record and send it at once to every connected mutual. A record for a mutual that is not connected is handed to it on the next connection. Old `seq` loses, always.
5. **Exchange on connect, forward on arrival.** When two mutuals connect, each sends its own record and the freshest record it holds for every device the two have in common (own devices, shared contacts and co-members). When a device receives a fresher record for a mutual, it forwards it to every connected device that shares that mutual, up to three hops, and dials the device if it is not connected (rule 2). This is how a friend coming online is seen by everyone within seconds, and how your other device learns your new contact the moment you add one.
6. **Carry and relay only on top.** `post` delivers to a connected device, else to connected own devices and connected mutuals of the recipient (carriers). Relay candidates come only from records. Nothing in carrying or relaying discovers anything; it uses what rules 1 to 5 established.

Every build is held to these numbers, measured by the crate's bench (`peer-node bench`) and by the lab: a friend coming online is seen by a connected mutual within 2 s (direct) or 5 s (through a relay); a record change reaches every connected mutual within 1 s; a contact added on one own device is a contact on the other within 1 s; reconnect after a relaunch, a wake or an address change takes under 2 s; a dead peer is marked offline within 60 s. An app shows these facts as its network picture, with sentences behind it: who is online, how they are reached, how old the record is, and who carries what.

## Finding, in order

1. **Cache and dial.** Every known device's last record, all addresses in parallel, before anything else.
2. **Push on change.** New network, new reachability, coming online: sign a record and send it to every connected cardholder; they forward it to mutual cardholders, three hops, old `seq` loses.
3. **Exchange on connect.** Both sides swap their own record and the freshest they hold for everyone both have a card for.
4. **Nearby.** mDNS on the LAN. Bluetooth in the room is a later step.

Cold start after a long absence, with every cached address stale and no reachable mutual, means meeting again by invite. That is the accepted cost. An always-on computer in anyone's circle makes it rare, and the UI shows records greying as they age so nobody is surprised.

## Policy: who carries what

Every stream declares a class. The crate enforces it; the app chooses it.

| class | examples | allowed paths |
|---|---|---|
| **live** | calls, screen, typing | direct, or relayed by a device belonging to *either end's person*; never a third person's |
| **bulk** | blobs of 50 MB and more, library sync | direct, or a device belonging to either end's person; never a third person's bandwidth unless they opted in for you. Measured: 55 MB/s direct against 0.09 MB/s through a third person's relay, so bulk through anything but a direct path or an own device is not a product |
| **small** | messages, records, envelopes, invites, metadata | any helper |

Per-friend overrides sit on top: *relay-only* (your record to them names a relay and no addresses, so they never see your IP), and, later, *may carry bulk for me*.

## The crate

The Rust crate `peer` is built on iroh 1.x with DNS lookup and pkarr publishing disabled, plus iroh-blobs, iroh-mdns-address-lookup, ed25519-dalek, blake3, postcard and rusqlite. It is exposed to Swift by UniFFI as `Peer` (the `PeerKit` package) and as a CLI, `peer-node`, for a headless device. App payloads are opaque bytes to the crate; apps bring their own sealing on top (baud's lives in its own core). `SPEC.md` has the surface. Contacts, cards and names replicate between a person's own linked devices inside the crate, so apps never sync the address book themselves.

**Links.** The link format belongs to the crate, not to any app: `format`, `parse`, test vectors, and a parser with no native code (`peer/js/parse-link.js`) so a static web page can read a link. There are two kinds a person makes, *friend* and *my own device*. Each is one use and carries the inviter's name; a friend link lasts an hour, a device link ten minutes. A third kind, the *reply*, is made by the app when a redeemer cannot reach the link's maker, and goes back the way the link came (`lab/MEETING.md` has why). An invite names a reachable device to meet at (see "baud, aggressively simple") rather than the inviter's live addresses, so the chat app that carried the link never learns an IP. Raw addresses ride in a link only when no helper exists. Removing a contact tells the other side over a live connection (a removal made while they are offline reaches them only as refused dials), and never drops the card of someone who is still a co-member. Groups carry their members' cards to every member, so an app never ships cards itself; who may then dial whom is the business of "Three tiers". Each app runs its own ALPN on top of the crate's. Key material never sits in an app-readable file: the crate takes a keychain item and seals its own store.

**Reachability probe.** On every network change a device sends a `Bind` to up to four devices it holds a card for, own devices first, and each answers with the address it saw. It also asks the router for a mapping (UPnP, NAT-PMP, PCP). The same port everywhere, or a confirmed mapping, means reachable. Answering a `Bind` costs a friend nothing and tells the asker only its own address, which the friend could already see. Fewer than two distinct responders across the internet means `reachable: unknown`: advertised as false, with inbound still attempted. One always-on device per circle is therefore not enough to probe with; two devices across the internet are. A LAN or VPN responder sees a local port and says nothing about the NAT. A mapping counts only once the router confirms it holds it, because routers have been seen answering success and storing nothing, and a peer across the internet checks it by dialing back. A helper is several URLs (public, plus one per LAN interface, because many home routers don't hairpin), so relay URLs are taken from every fresh record and a dialer treats a helper's URLs as aliases of one server. With a mapping on the home router, the home device is itself a hole-punch target and the relay is rarely used; the relay is what a laptop behind a symmetric NAT needs to reach an unmapped home device.

**Sync: `peer::catalog`.** Syncing is one of the four outcomes, and the op log that delivers it lives in the crate as `peer::catalog`: HLC `<ms>:<counter>:<device>`, field-level last-writer-wins, per-(group, device) marks, tombstones, signed ops. Tables are opaque to the crate; apps keep only their schema. The format came from darkroom and stays byte-compatible with the other implementations; `notes/catalog.md` describes it and `notes/catalog-vectors.json` holds the shared test vectors.

**Platforms.** The phone is the node. An iOS endpoint exists only while the app is awake, so `set_online(true)` must dial cached records in under 2 s, `post` must hand envelopes to any connected own device before the poster sleeps, and device keys are stored `AfterFirstUnlockThisDeviceOnly`. Porting rules: bindings call sync methods from threads with no async runtime, so the crate spawns only on the runtime handle captured at `open`; cc and rustc must agree on the deployment target (`IPHONEOS_DEPLOYMENT_TARGET=17.0`) or SQLCipher fails to link; and the iOS build uses rustup's toolchain, not Homebrew's, which has no iOS targets.

## Three tiers

- **Space: a closed network.** Joining a space is consenting to be friends with every member. Address records are shared among members, every member carries for every other, every connection inside is direct peer to peer, and nothing a space holds propagates outside it. The crate's group is the primitive: a space is a named group of people with channels, every channel has every member, and membership is explicit. Co-members need not be contacts, because the group carries their cards.
- **Group chat: everyone holds the whole chat, not everyone is friends.** Membership is the list, but your address record goes only to your friends in it. A member you are not friends with reaches you through a friend you share: that friend carries sealed bytes and sees a recipient, a size and a time. You never need to know the fourth or fifth person.
- **Direct: you and a friend**, carried by any mutual or your own devices.
- **Names.** Every person has a public name they chose, carried in their card. A contact's petname overrides it in your view. In a group you see people you are not friends with by their public name. No registry, no lookup: "no canonical names" means nobody can resolve a name to a key except through a card they were handed.

Messaging (direct and group chats) and spaces are two modes of one network, so nobody pairs or befriends twice.

For the crate, a group carries a kind, `space` or `chat`. In a `space`, members are mutuals: rule 1 of the loop applies to all of them, for records, dialing and carrying. In a `chat`, members are not mutuals unless they are also contacts; the group's events reach a non-contact only through a mutual who is in the group, and address records are never handed to non-contacts. Cards still travel with the group, so names and keys are known; addresses are not.

## Permissions

The network should let permissions be bolted on, and let permission structures emerge, without changing the transport. Permissions never live in the transport. The network answers who is a member and who can reach whom; what a member may write is the app's question, answered in the same signed log.

- The crate gives identity (every op carries its writer's key and signature), membership (who is in a group and who introduced them), and the verifier hook: `peer::catalog` shows each op to the app with its writer, group and signature state, and the app answers apply, hold or reject.
- Roles are ops. A grant ("Jo may edit here", "Ana may invite", "Sam may carry bulk for me") is a signed row in the group's own log, replicated like any row. An op whose grant has not arrived is held, not lost, and applies when it does. The chain starts at the founder: the first admin is the key that made the group, and every later role traces back to it through signed grants, so any member verifies any permission offline.
- Emergence: a new permission structure is a new grant kind plus a verifier rule; nothing in the crate's transport changes. darkroom's admin, editor and viewer roles, with held ops, are the first instance; per-folder roles and baud's channel roles are the same mechanism.
- Still to build in the crate: the group's membership and grants as their own signed log (`add_member`, `remove_member`, `grant` and `revoke`, each signed by the actor, carried with cards and verified by the chain), and the roles the crate can prove handed to the app's verifier with the `Writer`.

## baud, aggressively simple

baud is the first app on peer, and after its first real test between friends it was cut down to what a person needs. Chat comes first; spaces wait behind a flag. One add flow serves a friend and your own device, honest and without friction. The network is one picture that explains the idea. Carrying and delivery are icons, never prose. A person can reset the app and remove a device.

That cut added one crate rule: **an invite names the best meeting device.** That is your own reachable device first, then a reachable friend's device, then raw addresses, and the redeemer dials the meeting device first. Two devices with no inbound path (two phones on cellular) must meet through it. Bench row: two nodes with no port mapping add each other through a third, reachable node within 5 s. `SPEC.md`, "Links", has how the meeting device is chosen and how its relay admits the redeemer.

## Teaching stable devices

The one concept a person must get: a device that can be reached from outside (a computer at home) carries messages for them and their friends when phones can't find each other. It is taught once, with a picture, in onboarding: two phones apart, a line between them that fails, a computer appears, the lines light up through it, and a message crosses. Eight words at most, with "Add a computer" and "Later". After that it is shown, never explained again: a **stable** mark on every reachable device, the network picture anchored on it, and the add screen's unreachable state drawn as the same picture.

## Identity redirect

A person who started on two devices has two user keys, and linking them must be easy. Linking one device into the other person merges them. The old key signs `{ from, to, at, sig }`, and the statement travels in the new card and is pushed, sealed, to the old identity's contacts. A receiver holding the old card swaps the contact's key, keeps the petname, marks the trust as vouched by the old key, and tells the app so chats merge. From then on the old key is refused. Nothing is lost on either device. The crate owns this; an app keeps local chats when a device joins and merges them on the event. `SPEC.md`, "Identity redirect", has the details.

## The four outcomes

What the network must deliver, shown between two real devices on two different networks (a home network and a symmetric NAT), with a packet capture showing nothing sent to any non-peer host. First run to first friend should take under a minute, with no account.

1. **Address book**: add a friend by link, see them online, rename them, revoke them.
2. **Relaying**: a pair that can't punch connects through a helper, and the UI names it.
3. **Inboxing**: send to a friend who is offline; it arrives when they return, carried by a named device.
4. **Syncing**: your own devices converge, including after one was away.

`examples/README.md` reproduces each with `peer-node`.
