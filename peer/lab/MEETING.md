# Meeting by link alone: the options

**The gap.** Two people on unreachable networks with no friend in common cannot meet by link.
In a lab census run before reply links, 71% of pairs failed by link alone with mapping on, 92% with
it off; every one of them met through a friend's relay. A link is one-way. It tells the redeemer
where the inviter is. The inviter's network drops the redeemer's packets, because the inviter has
never sent any toward the redeemer, whose address it cannot know. A firewalled IPv6 phone
(`cell-xlat`, `cell60`, `v6home`) and a NATed IPv4 home are both unreachable this way.

What closes it is the inviter sending toward the redeemer at the same time as the redeemer sends
toward the inviter. Both stateful firewalls then let the other's packets in, and two NATs that keep
one port per socket can punch too. That needs the redeemer's address to reach the inviter. The
options differ in how.

Each is judged against two rules in `../DESIGN.md`: a device never reveals its address to people
its person doesn't know (rule 3), and no public relay ships (rule 2).

## 1. Two-way QR, in person

Each phone shows a code and scans the other's: each learns the other's addresses, and both dial.

- **Reveals:** each person's addresses to the other, standing in front of them, by choice.
  Nothing hosted.
- **Works for:** any pair with IPv6 on both phones (most phones today), and IPv4 pairs where one
  side knows its public address and port (a router mapping, or a recent probe through a friend).
  Not for two symmetric NATs (café ↔ café): they need a relay whatever the codes say.
- **Costs:** a scan each way, in person only.

## 2. A reply link

The redeemer's add fails; the app makes a reply link (the redeemer's addresses, tied to the
original invite) and asks the person to send it back over the same chat. Opening it, the inviter
dials; the redeemer, still trying, dials too.

- **Reveals:** the redeemer's addresses to the inviter, who sent them a link first. The redeemer
  chooses to reply. Nothing hosted.
- **Works for:** the same pairs as the QR codes, at a distance.
- **Costs:** a second message, and both apps trying within the same window (the invite's hour).
  An inviter who takes longer finds the redeemer gone, and they try again.

## 3. A minimal address rendezvous

A service both apps can reach holds each side's address for the moment it takes to introduce
them, then forgets it.

- **Reveals:** both people's addresses, and that these two are meeting and when, to whoever runs
  the service, a third party neither chose. A hosted service is exactly what rules 2 and 3
  exclude.
- **Works for:** the same pairs, with no second message.
- **The allowed form of it already exists:** a friend's or an own device running a relay is a
  rendezvous someone chose. The census meets every pair that has one.

## Decision

Option 2, the reply link, with option 1 when people are together. Both reveal addresses only to
the person being met and need nothing hosted. Option 3 would trade the address rule for one fewer
message, so it is not built. The reply link is built: see `../SPEC.md`, "Replies".
