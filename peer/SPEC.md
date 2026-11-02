# peer: API

The API reference for `peer`, the network crate under baud, which any app can embed: iroh 1.3 on `presets::Minimal`, no DNS, no pkarr, no n0 relay. `DESIGN.md` says how the network is designed and why. **[2]** marks what is planned for a later cut.

## Types

```rust
pub struct DeviceId([u8; 32]);  pub struct UserId([u8; 32]);  pub struct Sig([u8; 64]);
pub struct GroupId([u8; 32]);   pub struct Hash([u8; 32]);    // blake3
pub struct EnvelopeId([u8; 32]); pub struct ConnId(u64);      pub struct LinkReqId(u64);

pub struct Card { body: CardBody, sig: Sig }           // user key over the postcard body
pub struct CardBody { user: UserId, name: String, avatar: Option<Hash>,
    devices: Vec<DeviceEntry>, revoked: Vec<Revocation>, seq: u64 }
pub struct DeviceEntry { id: DeviceId, name: String, kind: DeviceKind, added_at: u64, app: Vec<u8> }
// DeviceKind: Mac, Iphone, Ipad, Windows, Linux, Node, Android, new ones at the end; on the wire its index. A
// later version's index is kept as it came (Unknown(n), shown "node"), so that card reads and still verifies.
pub struct Revocation { id: DeviceId, at: u64 }

pub struct AddressRecord { device: DeviceId, addresses: Vec<TransportAddr>, relay: Option<DeviceId> /* the helper I am homed on */,
    reachable: Reachability /* { udp: hole-punch target, tcp: can relay }; Unknown advertises false */, awake: bool, tags: Vec<String>, seq: u64, at: u64 }
pub struct SignedRecord { record: AddressRecord, sig: Sig }

pub enum Class { Live, Bulk, Small }
pub enum Path { Direct { vpn: bool }, Relay(DeviceId), Nearby, Waiting, Unreachable }
pub enum Reachable { Yes, No, Unknown }
pub enum FoundBy { Cache, Push, Exchange, Nearby, Invite }
pub struct RecordView { device: DeviceId, relay: Option<DeviceId>, reachable: Reachability, awake: bool, tags: Vec<String>, seq: u64, age_ms: u64, found_by: FoundBy }
pub struct PeerStatus { device: DeviceId, user: UserId, name: String, kind: DeviceKind, online: bool, path: Path, rtt_ms: Option<u32>,
    last_seen: Option<u64> /* unix ms; now while online */, record_age_ms: Option<u64>, found_by: Option<FoundBy> }
pub struct Identity { user: UserId, device: DeviceId, pinned: bool /* fingerprint verified; admission is the Conn itself */, own: bool, groups: Vec<GroupId> }
pub struct Person { user: UserId, name: String, avatar: Option<Hash>, fingerprint: String, devices: Vec<DeviceEntry>, this_device: DeviceId }
pub struct Contact { user: UserId, name: String /*petname*/, card: Option<Card>, verified: bool, relay_only: bool, met_at: u64, devices: Vec<PeerStatus>,
    redirected_from: Option<UserId> /* came by a redirect: vouched by that old key, not verified */ }
pub struct Redirect { from: UserId, to: UserId, at: u64, sig: Sig }   // signed by `from`'s key: "I am now `to`"
pub struct Envelope { id: EnvelopeId, from: Option<DeviceId> /* direct delivery only */, bytes: Vec<u8>, carried_by: Vec<DeviceId>, received_at: u64 }
pub struct Helping { envelopes: u32, bytes: u64, budget_bytes: u64, records_cached: u32, relaying: bool, relay_url: Option<String> }
pub enum Event { Online(DeviceId), Offline(DeviceId), PathChanged(DeviceId), Dialing(DeviceId) /* a dial began: "reaching Ana's Mac…" */, RecordChanged(DeviceId), Inbound { conn: ConnId, alpn: String },
    Delivered(EnvelopeId), Inbox(EnvelopeId), ContactsChanged, MeChanged, LinkRequest(LinkReqId), Removed /* another of my devices removed this one: reset */, ContactRemoved(UserId) /* a friend removed me: hide the chat */, ContactRedirected { from: UserId, to: UserId } /* merge the chats */, NetworkChanged, ReachabilityChanged(Reachable) }
pub enum Error { NotFound, BadKey, BadSignature, Encoding, Expired, Used, NotInTheirBook, Unreachable, PolicyRefused(Class, Path), Budget, Keychain(String), Store(String), Net(String) }
```

## Surface

```rust
pub trait Keychain: Send + Sync { fn get(&self, item: &str) -> Result<Option<Vec<u8>>>;
    fn put(&self, item: &str, bytes: &[u8]) -> Result<()>; fn delete(&self, item: &str) -> Result<()>; }
// items: device-key, user-key, store-key. A store records its device; open refuses another device's keychain.
pub struct Config { app: String, alpns: Vec<Vec<u8>> /* the app's */,
    nearby: bool /* mDNS, default true */, helper_budget_bytes: u64 /* 200 MB */,
    relay_url: Option<String> /* a helper behind a TLS terminator advertises this */, auto_confirm_links: bool /* headless */,
    relay: bool /* run the embedded relay on `port` (none: the endpoint's own, kept across restarts); advertised only while that port
                   is mapped (confirmed) or `public`, withdrawn when the mapping lapses */, public: bool /* port forwarded or address global: no probe */, vpn: bool, portmap: bool /* test switches */,
    link_scheme: String /* before `#`: the app's, e.g. `baud://add` */ }
pub struct Migration { device_secret: [u8;32], user_secret: [u8;32], name: String, devices: Vec<MigratedDevice> /* the whole old list */, card_at: u64 /* the first seq */ }
pub struct MigratedDevice { id: DeviceId, name: String, kind: DeviceKind, added_at: u64, addresses: Vec<TransportAddr> }
pub struct AdoptedDevice { id: DeviceId, name: String, addresses: Vec<TransportAddr> }

impl Peer {
  pub async fn open(dir: PathBuf, keychain: Arc<dyn Keychain>, config: Config) -> Result<Peer>;
  pub async fn adopt(dir, keychain, config, m: Migration) -> Result<Peer>;
  pub fn me(&self) -> Person;                     pub fn set_name(&self, name: &str) -> Result<()>;
  pub fn set_avatar(&self, hash: Hash) -> Result<()>;
  pub fn set_tags(&self, tags: Vec<String>) -> Result<()>;
  pub fn link_device(&self) -> Result<Link>;      // one use, 10 min
  pub async fn link(&self, link: &Link, device_name: &str) -> Result<()>;
  pub fn confirm_link(&self, req: LinkReqId, accept: bool) -> Result<()>;
  pub fn link_code(&self, req: LinkReqId) -> Result<String>;            // 6 digits from blake3(secret‖new‖old)
  pub fn link_request(&self, req: LinkReqId) -> Result<DeviceId>;       pub fn joining_code(&self, link: &Link) -> String; // the joiner's digits
  pub fn sign_as_user(&self, bytes: &[u8]) -> Result<Sig>;              // adopted stores only; transition
  pub fn revoke(&self, device: DeviceId) -> Result<()>;
  pub fn remove_device(&self, device: DeviceId) -> Result<()>;   // revoke, by its surface name; the device hears Event::Removed
  pub fn redirects(&self) -> Vec<Redirect>;       // identities merged: applied to my contacts, and the one this device issued
  pub async fn reset(&self) -> Result<()>;        // close, delete this device's keys and directory; open again to start over

  pub fn invite(&self) -> Result<Link>;           // one use, 1 h; link_url(&Link) renders it under link_scheme
  pub fn invite_meeting(&self) -> Meeting;        // { kind: Own | Friend | None, device, device_name, user, user_name }: what the next link names
  pub async fn add(&self, link: &Link) -> Result<Contact>;
  pub fn contacts(&self) -> Vec<Contact>;         pub fn rename(&self, user: UserId, petname: &str) -> Result<()>;
  pub fn remove(&self, user: UserId) -> Result<()>;
  pub fn verify(&self, user: UserId, fingerprint: &str) -> Result<bool>;
  pub fn set_relay_only(&self, user: UserId, on: bool) -> Result<()>;
  pub fn adopt_contact(&self, user: UserId, petname: &str, devices: Vec<AdoptedDevice>, card_at: u64) -> Result<Contact>;
      // migration: admitted now, unpinned, dialed on the app ALPN

  pub fn add_member(&self, group: GroupId, card: Card) -> Result<()>;   // co-member: admitted, carried for
  pub fn remove_member(&self, group: GroupId, user: UserId) -> Result<()>;
  pub fn create_group(&self, group: GroupId, kind: GroupKind) -> Result<()>;   // Space | Chat (DESIGN.md, "Three tiers")
  pub fn group_kind(&self, group: GroupId) -> Option<GroupKind>;
  pub fn group_members(&self, group: GroupId) -> Vec<Member>;  // { user, name /* their card's */, petname, contact, mutual, card }
  pub fn members(&self, group: GroupId) -> Vec<Card>;   pub fn groups(&self) -> Vec<GroupId>;  pub fn card(&self) -> Card;  pub fn card_of(&self, user: UserId) -> Option<Card>;

  pub async fn connect(&self, device: DeviceId, class: Class, alpn: &[u8]) -> Result<Conn>;
      // one cached Conn per (device, alpn)
  pub fn accept(&self, id: ConnId) -> Result<Conn>;                      // after Event::Inbound
  pub async fn post(&self, to: DeviceId, bytes: Vec<u8>, ttl: Duration) -> Result<EnvelopeId>;
  pub fn inbox(&self) -> Vec<Envelope>;           pub fn ack(&self, id: EnvelopeId) -> Result<()>;   pub fn outbox(&self) -> Vec<EnvelopeId>;
  pub fn records(&self) -> Vec<RecordView>;       pub fn peers(&self) -> Vec<PeerStatus>; // every device I hold a card for
  pub fn connections(&self) -> Vec<PeerStatus>;   pub fn helpers_for(&self, device: DeviceId) -> Vec<DeviceId>;
  pub fn nearby(&self) -> Vec<DeviceId>;          pub fn helping(&self) -> Helping;
  pub fn reachable(&self) -> Reachable;           pub async fn probe(&self) -> Reachable; // forced re-check
  pub fn set_online(&self, online: bool);         // `awake`, broadcast; true after false is a wake: every mutual redialed now
  pub fn network_changed(&self);                  // the platform's path monitor says so; the node also watches the OS itself
  pub fn trace(&self) -> Vec<String>;             // the timing log: one JSON line per milestone, newest 1024 (`peer::trace`)
  pub fn subscribe(&self, l: Arc<dyn Listener>);  // ids only
  pub fn sign(&self, bytes: &[u8]) -> Sig;        pub fn verify_sig(device: DeviceId, bytes: &[u8], sig: &Sig) -> bool;
  pub fn blobs(&self) -> &Blobs;                  pub async fn close(self);
}
impl Conn {
  pub fn identity(&self) -> Identity;  pub fn path(&self) -> Path;  pub fn rtt_ms(&self) -> Option<u32>;
  pub fn class(&self) -> Class;        pub fn alpn(&self) -> &[u8];
  pub async fn open(&self) -> Result<Stream>;  pub async fn accept_stream(&self) -> Result<Stream>;
  pub fn send_datagram(&self, bytes: Bytes) -> Result<()>;  pub async fn recv_datagram(&self) -> Result<Bytes>;
  pub fn max_datagram(&self) -> Option<usize>;  pub fn close(&self, reason: &str);
}
impl Stream { pub async fn send(&mut self, bytes: &[u8]) -> Result<()>; /* awaits flow control: backpressure */
  pub async fn recv(&mut self, max: usize) -> Result<Option<Bytes>>; pub fn finish(&mut self) -> Result<()>;
  pub async fn delivered(&mut self) -> Result<()>; /* finish, then the far side's QUIC acknowledged every byte; after a
     few round trips of silence from it, Unreachable, the connection closed and its device redialed. The bindings'
     `finish` is this: a send counts once the far side has it, so a frame on a dead connection is carried another way.
     A device that went silent so is refused by `connect` at once until a new connection to it forms (30 s at most),
     and a Small app dial gets a few round trips of the device's held path (`answer_wait`; one that runs out makes the
     device silent, and its envelopes go to carriers without trying it): a message goes to carriers, not into a dead path */
  pub fn set_priority(&mut self, p: i32) -> Result<()>; pub fn reset(&mut self) -> Result<()>;
  pub fn split(self) -> (SendHalf, RecvHalf); } // bindings lock the halves separately
impl Blobs {  // iroh-blobs behind the gate, bao-verified, always Bulk
  pub async fn add_path(&self, path: &Path) -> Result<Hash>;             // Hash is the file's blake3; a path
                                       // unchanged in size and mtime since its import is not read again;
                                       // four imports read at once, the rest wait their turn
  pub async fn has(&self, hash: Hash) -> bool;  pub async fn have(&self, hash: Hash) -> Vec<DeviceId>; // asks connected peers
  pub async fn fetch(&self, from: DeviceId, hash: Hash, to: &Path, range: Option<Range<u64>>) -> Result<Transfer>;
  pub fn transfers(&self) -> Vec<Transfer>;  pub fn local_path(&self, hash: Hash) -> Option<PathBuf>;
  pub async fn forget(&self, hash: Hash) -> Result<()>; } // stop holding; GC frees the bytes
impl Transfer { pub fn state(&self) -> TransferState /* Running | Waiting | Paused | Done | Cancelled */; pub fn progress(&self) -> (u64, u64);
  pub fn pause(&self); pub fn resume(&self); pub fn cancel(&self); } // pause keeps what is verified
```

Wire rule: a change to `peer/1`, `peer/join/1`, `peer/bind/1`, cards, records or links bumps the ALPN version or stays readable for one release; a store from an older cut keeps its identity and resets its book. Errors are flat. `connect` fails fast with `NotInTheirBook` (a round trip proves their gate closed us; a dial only relays can carry, every one of which denies us, is the same answer at once, not a timeout) or `PolicyRefused`, after `PathChanged`. On accept the crate verifies the QUIC device key is listed, unrevoked, in a card it holds and hands the app `Identity`.

## Links

`<link_scheme>#<frag>`; nothing after `#` reaches a server. Seven dot-separated fields, base64url unless noted:

```
peer1 . <kind> . <name> . <user> . <expires> . <meet> . <secret>
kind     "f" friend | "m" my own device                         (plain)
name     utf-8 inviter name, ≤ 64 bytes; format cuts longer names at a character boundary
user     32-byte user key                                       (43 chars)
expires  unix seconds, decimal                                   (plain)
meet     utf-8 "<device hex>;<addr>;<addr>…"  addr = ip:port | [v6]:port | relay=<url>
secret   32 random bytes                                        (43 chars)
```

The dotless form (0.2.10) is the same fields as one base64url token, with no dot for a chat app or an autolinker to take for the end of a sentence: `0x01` (peer1), the kind's tag byte, the name's length (one byte) and bytes, user (32), expires (8, big-endian), secret (32), then `meet` to the end. `parse` reads both (a fragment with no dot is dotless). Neither survived the apps links are sent through: Apple's link detector (Messages, Mail, Notes) ends a link before any run of more than 301 letters and digits, and `meet` with a relay in it (its URLs, each with the 139-character token, as base64 of text) made runs of 400 and more, so a link arrived cut after its expiry or its `#` (0.2.18, "not a baud link").

The grouped form (0.2.19), which `format` writes: `0x02`, then the dotless fields up to `secret`, then `meet` packed: the device (32), the meet token once (`0` none; `1` and its 64-byte signature, its device being the meet device and its expiry the link's; `2` and all 104 bytes), then each address as a tag and bytes (`4`/`6` and the IP and big-endian port: `ip:port`, `[v6]:port`; `0x14`/`0x16` the same as `relay=http://…/`; `0x34`/`0x36` with `?m=<token>`; `1`, a two-byte length and the text, for anything that doesn't come back byte for byte from those). All of it lowercase base32 (RFC 4648, no padding) in groups of 48 joined by `-`: letters and digits between dashes, ending on one, nothing a detector, Markdown or a chat app ends a link at or formats, and any case, dashes, spaces and line breaks read. A link through a helper is about 380 characters with its host, from about 970. `parse` takes a fragment that is base32 in one case and starts with `0x02` as grouped, then dotless or dotted as before (a dotless token begins `A` and a capital, which decode to 5). `vectors/links.json` holds all three.

Friend links last an hour, device links ten minutes. `meet` names the inviting device and where to reach it; a friend link minted where the meeting device is another of my own devices (a phone and its Mac) names that device instead, once it says it holds the invite (`Invite { secret, expires }`, a few round trips at most, else the link names me): it answers the redeemer whether or not I am awake, and the new friend reaches me through the book. **The meeting device** (DESIGN.md, "baud, aggressively simple"): this device if it runs a relay, else one of mine whose record does, else a contact's (`reachable.tcp`), a connected one before one that is not, then the freshest record; its relay URLs go in `meet`, each carrying `?m=<token>`, and none of my addresses (the carrying chat never learns my IP). No such device: my raw addresses (`MeetingKind::None`). The token is `device ‖ expires ‖ sig(device, "peer meet v1" ‖ helper ‖ expires)`, 104 bytes: the helper's relay admits a stranger presenting a token signed by one of its cardholders, for that helper, until the link expires, so a redeemer it has never met reaches the inviter through it, and through it reaches only the inviter's devices and the helper (a datagram to anyone else on the relay, or from them, is dropped as one to a device not there: the redeemer learns nothing of who else is on it); iroh punches through the relay and keeps it if the punch fails, and the helper sees ciphertext and sizes. A node homes on its meeting device's relay (its relay map holds only those URLs; other relays are dialed by URL; a URL at a private address is homed on, dialed or redeemed only from a network that address is on, a VPN one only while on the VPN: from elsewhere it answers nobody and iroh holds every relay's datagrams behind one still connecting), so a link always names a relay the inviter is connected to; `invite_meeting` says which before the link is shown, and apps mint the link when they show it. Links are not signed; the opener dials `meet` on `peer/join/1`, sends `Hello { secret, card, record }` (a device link: `Link { secret, device, name, kind, record }`, answered with key, card, book, records), and accepts the reply card only if its user key equals `user`. The secret burns once used: the person who redeemed it may ask again (an answer lost with its path gets the same answer; a Hello unanswered within ~4 RTT + 1 s is retried on a fresh connection), anyone else is refused `used`. `link::format`/`parse` are the only parsers; `vectors/links.json` is the contract; `js/parse-link.js` reads kind, name, user and expires, leaving `meet` and `secret` opaque.

**Replies** (kind `r`). A friend link whose maker the redeemer cannot reach (their network refuses strangers, and no friend's relay stands between them) is answered with a reply: the redeemer's name, user and a meeting device as an invite would carry them (its relay URLs with a meet token, else its raw addresses, IPv6 and IPv4, a router's port first), `secret = blake3("peer reply v1" ‖ link secret)`, expiring with the link or in 15 minutes, whichever is sooner. It goes back the way the link came (or as a code in person) and reveals the redeemer's addresses only to the link's maker, the one person who sent them theirs; nothing is hosted. Its maker keeps dialing the link's device, a fresh handshake every 3 s, so its own NAT and firewall stay open toward it. Opening it (`add`), a device of the link's maker that holds the invite (this one, or one of mine connected now, asked with `Reply(link)`) dials the reply's device for 15 s, a fresh handshake every 3 s, while it dials back: both networks open toward each other, and whichever dial gets through first completes the meeting with a Hello, the opener's with the reply's secret (answered only for the link's maker's user key) or the redeemer's with the link's. Either way both secrets are spent, and a late Hello from the same person with either is answered as a redeemed link's. An `add` of the link that gets through on its own spends the reply too; opened after, it gives the contact as it is. Two NATs that each give a new port per destination, or UDP blocked on a side, still need a relay.

**Identity redirect** (DESIGN.md, "Identity redirect"). A person who started on two devices has two user keys. When a device that already has a person (with contacts) links into another person, `link` keeps its book (its contacts become the new person's: own devices swap books on connect), and before the old user key is given up it signs `Redirect { from: old, to: new, at }`. The redirect goes with the new card (`Msg::Redirect { redirect, card }`; the card's own encoding is unchanged, so older nodes read new cards) to every device of every contact of the old identity, and to no one else: over a live connection, else sealed to the device as an envelope the crate opens itself (kept out of the app's inbox, outbox and `Delivered`), and again on that contact's next connection until one of its devices answers. A receiver that holds the old identity as a contact verifies the old key's signature and that the card is the new key's, then moves the contact to the new key: the petname stays, `verified` is false and `redirected_from` names the old key, group memberships follow, and `Event::ContactRedirected` lets the app merge the chats; it forwards the redirect to its own devices. From then on the old key is refused (a card, a book entry, an invite from it). A node that never had the old identity as a contact keeps nothing.

## Finding, records, probe

Records travel only to cardholders over `peer/1`: cache and dial, push on change (three hops, old `seq` loses), exchange on connect and on every book change, nearby (mDNS). A store rebinds its last UDP port and `close` releases it, so cached addresses survive restarts. Mutual cardholders are found without naming books: each sends `blake3(salt ‖ device)[..8]` per device it holds a card for; the other answers, forwards and carries by that set. A `relay_only` contact gets relays only: never my IP.

**Mutuals** (DESIGN.md, "Three tiers"): me and my own devices, contacts, adopted contacts, and every member of a `Space` I am in. A `Chat` co-member who is not a contact is not one: their card is held (name, key, sealing) and the group's cards still travel through mutual members (`Msg::Group { group, kind, cards }`; the older `Members` is read as a space), but they are not dialed or admitted (a member whose list lacks members I hold gets mine back, so one who kept the group after its maker's list was refused still learns the others), my want-list never names them so nobody hands me their record and I never ask for it, and what I post them goes to connected mutuals who hold their card (carriers). Records are signed, not sealed per recipient, so withholding them from a chat-only co-member holds for honest nodes; sealing records to each cardholder (DESIGN.md, rule 3) is what makes it hold against a dishonest one.

**The loop** (DESIGN.md, "The network loop"), from `open` to `close` whatever the app does: every mutual with a record is either connected or has a dial scheduled (1, 2, 4 … 60 s; back to 1 s on a fresh record for it, a new set of my IP addresses, `set_online(true)`, or its connection closing). A dial tries the record's addresses, the address its packets last came from (kept across restarts: a symmetric-NAT peer still dialing us is reachable exactly there), the record's relay and every connected own device's relay. **Introductions** race it (`peer::introduce`): up to four connected mutuals, own devices first, are asked `Introduce { salt, want }` (the target as `want_hash`, so a device that does not hold it learns nothing). One connected to the target, holding both, sends it `Punch { from, at, wait_ms }` (where it sees the asker; `wait_ms` is half the sum of its round trips to both, so the target's dial starts when the asker hears back) and, only once the target answers `Ok`, answers the asker `Introduced { at }` (where it sees the target): both dial at the same moment (a packet that reaches a Linux router before its own side has sent gets the outgoing dial renumbered), each at the address the other's NAT gave the go-between, and the asker's dial starts over with it. While an introduction is out, a dial leaves out where a punch will aim (the device's public IPv4 addresses, unless its record says they answer unasked: `reachable.udp`); nobody able to introduce yet is asked once more 1.5 s later. Only public addresses travel; a relay-only contact is never introduced either way; each role is spaced to once per 20 s per device or pair; a dial that answers a `Punch` never asks for an introduction, and none is asked for a device whose record says its app is closed. One dial per device is in flight; callers join it, unless a connection to the device is held, which answers an unforced dial at once. At most 64 requests are in flight on one connection either way (`MAX_ASKS`): past it an ask waits up to a second for one to end, then fails (`Budget`), and the far side takes no new request until one is answered, so a burst flows through and a loop that asks faster than its peer answers costs refusals, not memory. A second connection from the same side replaces the held one (that side redialed: restarted, woke, moved); from the other side, the lower device id's dial is kept unless it fails a `Bind` within ~4 RTT, then the new one wins. QUIC idle timeout 40 s with a keepalive every 20 s on the selected path only (none on the others), so a dead peer is offline within a minute. A Live connection (a call) is dialed with a 4 s idle timeout and a keepalive every second, which both ends adopt (QUIC takes the lower), and 5 s to connect: a call whose path died ends on both sides within seconds, never on one. Own devices swap the whole book on connect and push each edit at once (`Msg::Book`: contacts with cards, the records held for their devices, removals with their time; an edit's petname wins, a connect fills only what is missing, a removal after the meeting stays removed). Only a new set of IP addresses is a network change: a home relay moving among one helper's URLs is not, and an unchanged record is not re-sent. The node hears of one from the OS (its interface addresses, from a route socket or netlink; nothing on the network), from iroh, or from the app (`network_changed`): every held connection is checked by a record push (1.5 s, else redialed), a dial in flight for over 500 ms starts over (its handshake retransmits have backed off toward a network that is gone), and every mutual not connected is dialed.

**Probe**, on every network change, on `probe()` and once two direct peers exist: `Bind` to four devices with a direct path, own devices first, and to the host of each relay my connections ride, on `peer/bind/1` once a direct path to it forms (a device met through a friend's relay may hold no direct path to anyone, and without its public address no punch replaces the relay). Only a relay host serves `peer/bind/1`, only to the devices its relay admits (cardholders, and strangers whose meet token it accepted, until that link expires), and only `Bind`: each asker learns its own address, the host nothing it does not already see as relay; each answers with the source address it observed; only public answers count, each family on its own terms. IPv4: equal ports, or a gateway mapping, is `Yes`; differing ports `No`. IPv6: seen at one of this device's own addresses (untranslated) is `Yes`. Only an IPv4 answer is advertised as the public address; iroh knows its IPv6 ones. The endpoint binds IPv6 beside IPv4 on the same port wherever that port is free on IPv6, else on any. **Mappings** are the crate's (`peer::portmap`; iroh's own mapper is off): the endpoint's UDP port and a relay's TCP port, held for the node's life and renewed at half the lease, asked for again while none holds (at most once a minute, at once on a network change) on the port the endpoint is bound on, removed on `close`, asked for (UPnP) on the local port's own number first, then the external port used last time (persisted): a router's NAT sends the flows a device starts out from that port, so a far side behind a carrier's NAT that reached it on the mapping hears those flows too, and a start first sweeps its own leftovers from a crash. UPnP (igd-next) asks the default gateway alone, never the multicast group, so no other LAN device is contacted; NAT-PMP and PCP go through `portmapper`; both are asked at once (a NAT-PMP or PCP yes waits 250 ms for UPnP's), and a link minted in the first seconds waits up to 3 s for the first answer, so it carries the mapped address. A gateway's yes is not a mapping: one is used (it sets `reachable`, enters the record, lets a relay be offered) only once confirmed, by GetSpecificPortMappingEntry finding it for this address and port (UPnP) or by a second, separate request returning the same external port (NAT-PMP, PCP), and confirmed again at every renewal, every minute, and at once when a connection times out (a router that restarted forgot it: it is asked for again on the same port); an unconfirmed one is withdrawn. A router that answers success and stores nothing (seen on a home router after a power outage) leaves a node with no public address, and its links carry none. A confirmed one may still forward nothing, so a probe responder that sees this device across the internet (a direct path, public IPv4) at the mapping's own address is asked `Check { udp, tcp }` (two at most): it dials back from a throwaway endpoint (its own would ride the path they share) to that address and no other, a handshake with this device's key through the UDP port and a relay answering on the TCP one, and answers `Checked`. A mapping no checker got through is withdrawn (from the addresses, the links, `reachable`; the relay is not offered on it) until a later check does; with nobody to ask, the gateway's word stands. A checker answers once per asker per 10 s, and only over a direct path across the internet: over a relayed one it would show the asker where it is. 

## Helpers

Every device helps everyone whose card it holds. **Cache**: freshest record per device. **Carrier**: envelopes `{ to, expires, hops, ciphertext }`, 14 days, 200 MB, three hops. `post` seals the bytes to the recipient device key (ephemeral X25519 against its Ed25519 key, HKDF-SHA256, ChaCha20-Poly1305, `{to, expires}` bound in): carriers see `{to, size, expires}`; only that device opens it. `post` delivers directly when the recipient is connected, else copies to connected own devices and cardholders of the recipient; each new connection gets what is held for it plus copies it could carry on; the recipient broadcasts an ack, carriers drop and forward it once, and answer a re-handed envelope with it, so a returning sender learns `Delivered`. **Relay**: a `reachable` device runs an embedded `iroh_relay::server`, admitting cardholders and the holders of a cardholder's meet token (Links); its record carries `relay: Some(self)` and its URLs, public and per LAN interface. Cardholders home on their meeting device's (Links) and dial a peer homed on any of a helper's URLs through all of them: iroh's punch machinery has its rendezvous. Plain HTTP between peers (the payload is QUIC, end-to-end); pinned certs **[2]**. The TCP port is mapped with a second `portmapper` client and `relay` is advertised only with `reachable.tcp` (that mapping, or `public`): there is no TCP hole punch, so an unmapped relay is never offered. Budget per friend 1 GB/day, own devices unlimited.

## Policy

| class | paths | on degrading to a third person's relay |
|---|---|---|
| Live | `Direct`, `Relay(d)`, d owned by either endpoint's person | `PathChanged`, then `PolicyRefused` |
| Bulk | as Live | a `Transfer` goes `Waiting`, retries from what is verified. "May carry bulk for me" **[2]** |
| Small | any | carries on |

## iOS

`open` under 300 ms; `set_online(true)` dials cached records in 2 s; `post` returns once carried.

**Nearby needs Apple's multicast entitlement.** `nearby` is mDNS over raw sockets (iroh-mdns-address-lookup on swarm-discovery: UDP 5353, 224.0.0.251 and ff02::fb, service `_peer-<app>._udp`). On iOS an app may send or receive multicast only with `com.apple.developer.networking.multicast`, which Apple grants on request (developer.apple.com/contact/request/networking-multicast); without it the sockets open, `open` succeeds, every send fails and nothing arrives, so nearby does nothing, silently. The crate says so: at open it sends one empty mDNS query and traces `nearby { ok, err }` (and warns). The request names the app and its bundle id and says: the app discovers the person's own devices and friends' devices on the same Wi-Fi with mDNS/DNS-SD to connect peer to peer without a server; the same protocol and implementation run on macOS, Windows and Linux, so it cannot use NWBrowser/NetService; it sends and receives only mDNS (UDP 5353, 224.0.0.251, ff02::fb) on the local network. Bonjour instead (NWBrowser, no entitlement) is not a drop-in: the crate's nodes answer a browse with SRV, TXT and A but no PTR, which mDNSResponder needs to list them, so both sides would have to change. Nothing else depends on nearby: records and links carry LAN addresses, and dialing those needs only Local Network access (`NSLocalNetworkUsageDescription`, granted by the person).

## Store and keys

SQLite via rusqlite `bundled-sqlcipher` (OpenSSL vendored on Windows), keyed by `store-key`. `adopt(Migration)` imports an earlier app's keys unchanged and signs the first card from the whole old device list at `seq = card_at`, so devices migrating alone sign the same body (equal-seq cards merge by union); they are dialed on the app ALPN until they answer `peer/1`. `adopt_contact` keeps a friend dialable and admitted until a real card replaces the placeholder.

## Bindings

- **UniFFI** crate `peer-uniffi` → Swift package `swift/PeerKit` (module `PeerKit`, class `Peer`; `scripts/build-swift.sh`), XCFramework for iOS, simulator and universal macOS; `Keychain` and `Listener` are callback interfaces. Bindings call sync methods from any thread. No panic crosses into Swift: every entry point catches one (it is in the trace, `ev: panic`, as is any thread's) and answers as `Failed`, or for a call that cannot fail as its neutral value (empty, `Unknown`, `Unreachable`); and the crate's locks are taken back when poisoned (`peer::sync`), so one task's panic leaves every later call working. `PeerError` has one case per crate error (`Unreachable`, `NotInTheirBook`, `Expired` …, each with the message; `Failed` for the binding's own). The binding's `Config` takes `relay`, `public` and `port` (UniFFI defaults: false, false, none), so a computer at home running an app is its own meeting device. It exposes `Conn`, `Stream`, `Blobs`, `Transfer`, `Catalog`, groups, `adopt`, `adopt_contact`, `card_of`, `link_request`, `joining_code`, `sign_as_user`, `helpers_for`, `Reachable`, `StreamClass`.
- **`peer-node`**: `init`, `status`, `run` (online; events printed; stdin commands for every call above; flags `--port --relay --public --auto-confirm-links --scheme`); file keychain 0600.

## Release gate

`policy::hosts` lists every configured relay URL; `peer/tests/gate.rs` asserts it is empty but for peers' relays, and that the code never names `presets::N0`, `RelayMode::Default`, `iroh.link`, `n0.computer`, `pkarr`. `peer-node gate` is the runtime gate every app runs.

## peer::catalog

The op log that syncs an app's tables, from darkroom and byte-compatible with its TypeScript and Swift implementations: `notes/catalog.md` has the format, and `peer/tests/catalog_vectors.rs` runs its shared vectors (six cases, four arrival orders each). The app brings `Config { tables: [{ name, keys }], schema }`. `Op { id, space, device, hlc, table, row, field, value, tombstone, sig }` is signed by the device over `canonical()`; HLC `<ms>:<counter>:<device>`; field-level last-writer-wins; liveness from clocks alone. `write` signs, applies and returns the op to push; `apply(ops, resolve_user, verify)` asks the app's `verify(op, Writer { device, user, group, sig_ok }) -> Apply | Hold | Reject`; held ops ride along with later deliveries; a batch whose row cannot exist yet is held whole; `marks(group)`, `since(group, marks, limit)`, `held()`. Apps read their typed tables directly, so two crate tables are stable contract: `field_clock(tbl, row, field, hlc)` (winning HLC per field; `__row` the tombstone) and `row_space(tbl, row, space, deleted)`; `op` and `held` are the crate's. Bindings: `peer.catalog(path, tables, schema)`, ops as JSON, a `Verifier` callback. The push/pull loop over `Conn` stays the app's.

