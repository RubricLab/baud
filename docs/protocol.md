# How baud's network works

baud carries messages between people's devices with no server in the middle. The network layer
is [`peer`](../peer), a Rust library built on [iroh](https://github.com/n0-computer/iroh) (QUIC).
A device is reached by its key, shares its address only with people it knows, and connects
directly whenever it can. When it can't, a device of yours or of a friend relays the sealed bytes,
or holds them until the recipient is back.

This page explains how it works today, what each party can see, and what it doesn't do yet. The
same text is published as a whitepaper at [sovereign.rubric.sh](https://sovereign.rubric.sh/whitepaper).

- [Keys](#keys)
- [The handshake](#the-handshake)
- [The address book](#the-address-book)
- [Connecting](#connecting)
- [Trusted relays](#trusted-relays)
- [Conversations](#conversations)
- [Waking an iPhone](#waking-an-iphone)
- [What others can see](#what-others-can-see)
- [On your device](#on-your-device)
- [Limits](#limits)
- [Where it lives in the code](#where-it-lives-in-the-code)

There is no account, no phone number, no directory, no certificate authority, and no central
relay or addressing server. A test holds the code to this: a fresh node knows no host but its
peers, and names no public relay, DNS lookup or discovery service.

## Keys

Each install of baud is a **device**. On first run it makes an Ed25519 key pair and keeps the
private half in the system keychain. The public half is the device's address on the network,
and the only thing anyone dials.

A **person** is a second key, shared by all of their devices. It signs the person's **card**:
their name, their picture, their devices, and the devices they removed. A card never holds an IP
address, and a newer card replaces an older one.

**Adding a device.** One of your devices shows a code that works once, for ten minutes. The new
device opens it, both screens show the same six digits, and you confirm. The new device receives
the person key, the card and your contacts. From then on a change on one of your devices reaches
the others within about a second of them connecting.

**Removing a device** revokes it in the card. Every contact who receives the new card refuses
that device's key.

## The handshake

Two people become contacts in a handshake: each gives the other their public keys and a way to
reach them. Private keys never leave their devices.

A handshake starts with a **link**, shown as a QR code or sent as a message. It works once and
expires after an hour. It carries the inviter's name, their person key, where to reach them and a
random secret, all after the `#`, so a web page that opens the link never sends any of it to a
server.

The person who opens the link dials the place it names and presents the secret with their own
card. The inviter answers with theirs, which the opener accepts only if it matches the person key
in the link. The secret is then spent, and each side holds the other's card.

**Where to reach the inviter.** The link names a meeting device: one of the inviter's devices
that can be reached from the internet, or a reachable device of one of their friends, with a
short token, signed by the inviter, that lets the holder in until the link expires. The inviter's
own IP addresses stay out of the link unless no meeting device exists.

**Safety numbers.** Every person key has a 60-digit safety number. Two people who compare theirs
in person or on a call know nobody swapped the link on the way.

## The address book

There is no directory. Each device keeps an address book: the latest **address record** of every
device it knows. An address record is a device's own signed description of where it is: its IP
addresses and ports, whether it can be reached from outside, its relay, and whether the app is
open. A newer record replaces an older one.

Records go only to **mutuals**: your own devices, your contacts' devices, and the members of a
space you joined. They spread four ways.

- **Cache.** The last record of each mutual is kept across restarts and dialed first.
- **Push.** When a device's network changes, it signs a new record and sends it to every mutual
  it is connected to. They pass it on to others who know that device, up to three hops.
- **Exchange.** Two devices that connect swap their own records and the freshest ones they hold
  for the devices they both know.
- **Nearby.** On the same Wi-Fi, devices also find each other with mDNS.

A device keeps dialing every mutual it holds a record for, backing off from one second to a
minute, and starts again the moment a fresh record arrives or its network changes. A device is
online to you exactly when you hold a live connection to it: a friend who comes online is seen
within seconds, and one who leaves is marked offline within a minute.

## Connecting

Devices talk over QUIC, using iroh. Every connection is encrypted with TLS 1.3 between the two
devices' keys, so it is end to end even when a relay forwards it. A device accepts a connection
only from a device listed, and not revoked, in a card it holds, or from someone holding a live
invite. Anyone else is turned away as soon as they identify themselves.

A direct connection is the goal: it is the fastest path, and nobody else is involved. Every
device listens on IPv4 and IPv6 on the same port, so an address a friend saved stays good across
restarts, and a dial tries every address at once: the same Wi-Fi, IPv6, IPv4. Whichever answers
first and fastest is kept, with the internet's IPv6 preferred when the two are close. Most
devices sit behind a router or a firewall, so a device has three more ways through.

- **Open a port.** It asks its own router for a port mapping with UPnP, NAT-PMP or PCP, and trusts
  the mapping only once the router confirms it. A device with a mapping can be reached from
  anywhere.
- **Ask what others see.** It asks up to four devices it is connected to, its own first, where its
  packets arrive from. Over IPv4, if they all see the same port, its router keeps a stable
  mapping. Over IPv6, if they see one of its own addresses unchanged, nothing translates it.
  Either way others can reach it with a punch. No outside server is asked.
- **Be introduced.** When a device dials someone it is not connected to, it asks up to four
  devices it is connected to, its own first, to introduce them. It names the person's device only
  by a salted hash, so a device that doesn't already know them learns nothing. One that is
  connected to both, and holds both cards, asks the other side first. If it agrees, it tells that
  device where it sees the caller and to dial back now, and tells the caller where it sees that
  device. Both then send at once, and each router or firewall lets the other's packets in.

When none of these works, the bytes go through a trusted relay. A punch fails where both sides sit
behind a router that picks a new port for every destination, as many cellular networks do over
IPv4, or where a network blocks UDP.

```text
Direct                    You ─────────────────── Ana

Through a trusted relay   You ──────── Jo ──────── Ana

Carried                   You ──────── Jo  ┄┄┄┄┄┄┄ Ana   (later, when Ana is back)
```

## Trusted relays

A trusted relay is always a device of yours or of someone you know, never a public server. Your
own devices help first, then your friends'. A relay helps in two ways.

**Forward.** A device that can be reached from outside, usually a computer at home with a port
open, admits only devices it knows and people holding an invite that names it. It forwards the
encrypted packets of two devices that couldn't punch through to each other. It forwards up to
1 GB a day for each friend, and without limit for its own person's devices.

**Carry.** When the recipient is offline, the sender seals the bytes to the recipient device's
key, with X25519, HKDF-SHA256 and ChaCha20-Poly1305, and hands copies to connected devices that
know the recipient. A carrier holds the envelope for up to fourteen days, within a 200 MB budget,
and passes it at most three hops. When the recipient connects to any carrier, it takes the
envelope and acknowledges it. Every carrier then drops its copy, and the sender learns it was
delivered.

Every stream also declares a class, and the network enforces it, so nobody's bandwidth is spent
on someone else's heavy traffic.

| Class | For | May travel |
| --- | --- | --- |
| Live | Calls, typing | Direct, or through a device of one of the two people. Never through a third person. |
| Bulk | Files over 50 MB | The same as live. A transfer waits rather than use a friend's bandwidth. |
| Small | Messages, records, envelopes | Through any trusted relay. |

You can also mark a friend **relay only**. Their copy of your record then names a relay and no
addresses, so they never learn your IP.

## Conversations

The network carries opaque bytes, and baud gives them meaning. Each conversation (a chat, a
group, a channel in a space) has its own key. Every frame is sealed with ChaCha20-Poly1305 under
that key before it reaches the network, so a relay or carrier holds bytes it can't open even
before the network's own encryption. A new member receives the key in the frame that adds them.

A conversation is a log of events. Devices exchange what the other side lacks when they connect,
so a message written offline goes out the next time a path exists, and nothing written is lost
across restarts. Delivery is data, not decoration: the line under a message says whether it was
sent, carried by which device, delivered to which device, or read, and it is built from receipts.

Messages can disappear. The setting is a line in the conversation that says for how long (anyone
in a chat may change it, only an admin in a channel), and each message written while it is on
carries its own time, so when it goes never depends on when the setting arrived. Each device
removes my message that long after I sent it, and anyone else's that long after any of my devices
first read it; an unread message waits. Its words, files, edits and pin go from that device. The
bare entry stays, so devices still agree on what each holds and nobody sends it again.

## Waking an iPhone

iOS pauses an app's network soon after it leaves the screen, and only Apple can wake a sleeping
iPhone. So baud has one small server, the **wake relay** ([`wake/`](../wake)), whose only job is
to ask Apple to wake a phone. It never sees a message.

1. The iPhone takes its push tokens from Apple and seals them to the relay's public key (HPKE:
   X25519, HKDF-SHA256, ChaCha20-Poly1305) as a **ticket** that lasts three days. Only the relay
   can open it, and the key is pinned in the app.
2. The iPhone hands a ticket to every device it connects to, its own and its friends'.
3. When a friend's message or call can't reach that iPhone live, their device posts the ticket
   to the relay.
4. The relay opens the ticket, checks its expiry and the rate limits, and sends Apple the same
   content-free push it sends everyone. The phone wakes, connects, and takes what's waiting peer
   to peer.

The relay has no accounts, no database and no request log. Its rate limits live in memory, keyed
by a keyed hash of the token, and die with the process. A friend you stop seeing can wake you
only until their ticket expires.

## What others can see

| Who | What they learn |
| --- | --- |
| A stranger | Nothing. Your address never reaches them, and your devices refuse their connections. |
| Your internet provider | That your device exchanges encrypted packets with certain IP addresses, how much and when. |
| A contact | Your name, your devices, when you are online, and your IP addresses unless you marked them relay only. |
| A go-between | That two devices it already knows want to connect, and the addresses it already sees them at. |
| A relay | Which two devices are talking, how much and when. Not what they say. |
| A carrier | Which device an envelope is for, who handed it over, its size and its expiry. Not what it says. |
| The wake relay | That a device at some IP address asked to wake some iPhone, and when. Not who either of them is, and nothing they say. |
| Apple | That your iPhone was sent a wake, and when. |

## On your device

Three keys live in the system keychain: the device key, the person key, and a key for the local
store. On iPhone they stay on that phone: they don't sync to iCloud and can't be restored onto
another phone. Everything else, including contacts, records and envelopes held for others, is
kept in a database encrypted with SQLCipher under the store key.

## Limits

- **No independent audit yet.** Neither the cryptography nor the code has been reviewed by an
  outside party.
- **No forward secrecy inside a conversation.** A conversation key doesn't ratchet, so someone
  who steals it can read that conversation's past frames if they also captured them.
- **Records are signed, not sealed.** A record goes only to mutuals, over encrypted connections,
  but is not encrypted to each recipient, so a dishonest mutual could pass yours on.
- **Relays see who talks to whom.** Never what is said, but which devices, how much and when.
- **Two phones alone may not meet.** Two phones on cellular data, with no device that both are
  connected to and none that can be reached, have nobody to time a punch. A computer at home that
  stays on fixes it.
- **Some networks defeat every punch.** A router that picks a new port for every destination on
  both sides, or a network that blocks UDP. A trusted relay carries the bytes then.
- **Phones help others only while open.** iOS pauses an app's network in the background, so a
  phone relays and carries for others only while baud is on screen or just after. A wake brings
  it online to receive, not to serve.
- **Older versions keep disappearing messages.** baud 0.2.19 and earlier ignore the setting and
  keep the messages.
- **Stale addresses mean meeting again.** If every address you hold for someone is out of date and
  nobody in your circle can reach them, you need a new link.

## Where it lives in the code

| Topic | Code |
| --- | --- |
| Keys, cards, devices | [`peer/peer/src/identity.rs`](../peer/peer/src/identity.rs), [`card.rs`](../peer/peer/src/card.rs) |
| Links and the handshake | [`peer/peer/src/link.rs`](../peer/peer/src/link.rs), [`api.rs`](../peer/peer/src/api.rs) |
| Address records and finding | [`record.rs`](../peer/peer/src/record.rs), [`finding.rs`](../peer/peer/src/finding.rs) |
| Port mapping, probes, introductions | [`portmap.rs`](../peer/peer/src/portmap.rs), [`probe.rs`](../peer/peer/src/probe.rs), [`introduce.rs`](../peer/peer/src/introduce.rs) |
| Relays and carrying | [`helper.rs`](../peer/peer/src/helper.rs), [`policy.rs`](../peer/peer/src/policy.rs) |
| The QUIC endpoint (no public servers) | [`transport.rs`](../peer/peer/src/transport.rs) |
| The encrypted store | [`store.rs`](../peer/peer/src/store.rs) |
| Conversations, sealing, sync | [`core/baud-core/src/wire.rs`](../core/baud-core/src/wire.rs), [`carry.rs`](../core/baud-core/src/carry.rs) |
| Wake tickets | [`core/baud-core/src/wake.rs`](../core/baud-core/src/wake.rs), [`wake/src/ticket.rs`](../wake/src/ticket.rs) |
| Changes to iroh | [`peer/vendor`](../peer/vendor) (marked `peer:`) and the note in [`peer/Cargo.toml`](../peer/Cargo.toml) |
