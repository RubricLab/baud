# Three proposals (not implemented)

**Decided.** Three principles govern the network: people must be able to communicate; it must be
secure; a device never reveals its address to people its person doesn't know (`../DESIGN.md`,
rule 3). So: 1 is off (no carry tokens for strangers; a relay carries two people only when its
owner holds both their cards). 2: port prediction only (add `cgnat-eim` and `cgnat-block`, then
sequential prediction), no spraying. 3: not now.

Each proposal says what it would change about who can reach whom and what is revealed to whom.
The failing rows it names are `lab.py` scenarios, as they stood when it was written.

## 1. The friend-helper gap: carry tokens

**What fails.** `relay:*` and `relay-home:*` · reconnect after both relaunch: 8 rows, the largest
remaining fail block. Ana and Bo met through Rex's relay. Rex is Ana's friend, not Bo's. The meet
token in Ana's link let Rex's relay admit Bo for the link's hour, and Bo never keeps it. After a
relaunch Bo dials Ana through Rex's relay without a token, and Rex refuses him (he is not a
cardholder). Ana has no relay of Bo's to reach him through. Where both are behind carrier NAT, or
one is UDP-blocked, there is then no path at all. A pair that can punch directly (two home routers)
now gets through anyway.

**Design.** While Ana and Bo are contacts and Ana's meeting device is a friend's relay, Ana gives Bo
a carry token over their authenticated connection. It is the meet token's shape plus Bo's device
id, signed by Ana's device, naming Rex, and valid for 7 days. Ana re-issues it on every connection,
so removing Bo stops it within 7 days. Rex's relay admits a client presenting a carry token signed
by one of its cardholders, naming Rex, naming that very client, and unexpired. Bo presents it when
dialing Ana. If Bo has no meeting device of his own, he homes on Rex's relay with it, so Ana can
reach him too. The same applies symmetrically: Bo's meeting device carries Ana on Bo's token.
Recommended with it: a patch to the relay server so a token-admitted client may exchange packets
only with the issuer's devices. When this was written, a meet-token holder could send to any device
connected to the relay for the link's hour, and the relay's "endpoint gone" replies told it which
device ids were online there. That patch has since landed on its own: a meet-token holder now
reaches only its inviter (`../SPEC.md`, "Links").

**Who can reach whom.** Bo can reach Ana through Rex's relay for as long as they are contacts, not
just for the link's hour. With the destination patch he reaches nobody else there. Nobody new is
admitted: only people a cardholder vouches for, and only to that cardholder.

**What is revealed.** Rex learns Bo's device id, the IP his TCP connection comes from, when he is
online (if he homes there), and the timing and volume of his traffic with Ana, for as long as they
are contacts. Today Rex learns this for the link's hour. Rex never sees content, cards or names.
Bo learns Rex's relay addresses, which Ana's link already gives him today. Rex would need a
setting ("carry my friends' contacts") and a cap; whether it would default on is an open question.

**Rows it should fix.** relay:{cgnat-home, cgnat-cgnat, double-mobile, udpblock-home, lossy-cgnat}
and relay-home:{cgnat-cgnat, cgnat-home} · reconnect after both relaunch.

## 2. Port prediction for carrier NAT

**What fails.** intro:{home-cgnat, cgnat-cgnat, double-home} · mutuals connect. The lab's `cgnat`
is the hardest case: a random port per destination, with address-and-port filtering (`MASQUERADE
--random-fully`). An introduction hands each side the port the go-between saw, and the peer's
packets come from a different one. A relay carries such pairs where one exists
(intro-relay:cgnat-cgnat passes). Real carrier NATs vary. RFC 6888 asks for endpoint-independent
mapping, which today's punch already handles. Others allocate per destination, sequentially or in
port blocks. The lab has neither variant yet, so the first step is adding `cgnat-eim` and
`cgnat-block` environments to measure what each approach buys.

**Design, in order of cost.**
- (a) Sequential prediction. The hard side asks two responders back to back and sees ports p and
  p+k. The go-between passes "next port about p+2k" along with the address. This costs nothing
  extra on the wire, does nothing against random allocation, and is fooled by other subscribers
  sharing a port block.
- (b) Easy-to-hard spray (Tailscale's "birthday" technique). The go-between already sees which side
  is hard: its probe says ports differ. The hard side opens 64 to 256 sockets, each sending one
  packet to the easy side's public address. The easy side sends to random ports on the hard side's
  IP, capped at about 1,000 packets over 3 s, until one gets through. This needs a vendored-iroh
  change: iroh owns a single socket, and a path found on an extra socket cannot carry the QUIC
  connection today.
- Hard to hard (cgnat-cgnat) stays relayed. The spray odds are too poor.

**Who can reach whom.** Unchanged. Only mutuals a go-between holding both introduces, with the
target's consent, as today.

**What is revealed.** The go-between additionally passes each side's NAT kind (easy or hard) and,
for (a), a port guess. For (b), the easy side sends up to about 1,000 UDP packets to random ports of
the other person's carrier IP. Ones that land on other subscribers' open mappings reach strangers
as stray probe packets carrying no content. A carrier's abuse detection may read the burst as a
port scan. The hard side holds up to 256 extra sockets for a few seconds, which costs battery and
data on a phone.

**Recommendation.** Add the two lab environments first. Implement (a) if `cgnat-block` shows it
helps. Do (b) only if the data says real carriers need it.

## 3. TCP fallback for UDP-blocked networks

**What fails.** pair:{udpblock-pub, pub-udpblock} · meet by link. With no relay in the circle,
direct QUIC is UDP only. With a relay friend, UDP-blocked networks already work over TCP 443
(relay:udpblock-home meets and messages; its reconnect is proposal 1).

**Design.** A reachable device serves its own relay for its own contacts and invitees, without the
`relay` setting. Reachable means public, or behind a router that maps a TCP port; the mapping and
the outside check already exist (`../SPEC.md`, "Finding, records, probe"). Its links then name its own relay, so a redeemer on a
UDP-blocked network comes in over TCP, to the inviter itself. Networks that allow only TCP 80 and
443 need the relay on external port 443: bind it where allowed (macOS lets unprivileged apps bind
low ports; Linux needs a capability), or ask the router for external 443, which many permit. Behind
a corporate proxy that blocks plain websockets, the relay would need TLS with a certificate pinned
to the device's key. That is a TLS change and a separate decision.

**Who can reach whom.** Same principals as any relay today: cardholders and live meet-token
holders. The new path leads to the inviter's own device, so no third party carries anything.

**What is revealed.** Every reachable device listens on a public TCP port, and on 443 where it can.
A port scan finds an HTTP service that answers an iroh relay handshake and refuses strangers, which
identifies "this IP runs peer". The IP itself is already in that device's links and records. A
router mapping for TCP 443 also shows in the router's UPnP table.
