# peer network lab

Real `peer-node` devices behind emulated routers, in Docker on a Mac. Each scenario builds a
small isolated internet (a core box that routes between sites and drops everything else), runs
the devices, measures them against the numbers in `../DESIGN.md` ("The network loop"), and tears
it all down. Nothing in the lab can reach the real network: no lab box routes anywhere but the
core, and UPnP, NAT-PMP and PCP only ever reach the lab's own routers.

Needs Docker Desktop running (`open -a Docker`).

    lab/lab.py run                      # the whole matrix at HEAD (about 30 min)
    lab/lab.py run --only intro         # scenarios whose name starts with "intro"
    lab/lab.py run --only dyn:home-upnp # one scenario
    lab/lab.py run --rev <commit>       # against any commit
    lab/lab.py run --wan-delay 0        # no internet latency: the hardest case for punching
    lab/lab.py list                     # what there is

`--rev` builds `peer-node` for Linux from a clean git worktree at that commit (cached in
`~/Library/Caches/peer-lab`), so uncommitted work never leaks into a run. Results land in
`lab/results/<rev>-<date>.md`, with raw logs per device (events, the crate's JSON trace, and
every lab mark, all on the Docker daemon's clock) in `lab/results/logs/`. They stay on your
machine and are not part of the repo.

Every link into the lab's internet has 20 ms one-way delay by default (`--wan-delay 0` for none).

Every router has a home router's firewall: nothing unsolicited from the WAN reaches the router
itself. A packet it drops leaves no conntrack entry. A router without one (`bare`) accepts a stray
packet from a peer that punched first, its conntrack then holds that tuple, and its own device's
punch toward that peer is renumbered. That case passes only when both sides start together.

Environments (`ENVS` in lab.py): public; home NAT (one port per socket, replies only from where
it sent); the same with UPnP + NAT-PMP + PCP (miniupnpd), NAT-PMP + PCP only, or a router that
grants mappings and forwards nothing; carrier NAT (a new random port per destination); home
behind carrier; IPv6 with a stateful firewall, with and without carrier IPv4; IPv6 open; UDP
blocked (TCP 80/443 only); 10% loss with 150 ms ± 50; UDP mappings forgotten after 30 s; a home
router with no firewall of its own (`bare`).

Scenarios: `pair` (two strangers meet by link, message, path, both relaunch), `relay` (the same
with a public relay friend on port 443 in the circle), `relay-home` (the relay friend behind a
mapping router, offered at its mapped and LAN addresses: its LAN URLs must stay out of dials made
away from that LAN), `relay-liar` (the relay friend behind a router that maps and forwards
nothing), `vpn` (both also on one Tailscale-style tailnet, 100.100.0.0/24), `intro` (two mutuals
behind NATs and a friend who reaches both: they must connect), `dyn` (wake after 30 s frozen, a
network move mid-session, the far router rebooting, a dead peer), `meetmove` (a relay host leaves
the network where its port was mapped).

The demo (a group chat Carl's Mac proxies, phones that move and sleep): `circle` (Jo and Sam,
each Carl's contact, in a chat, a space, or contacts through Carl's relay: messages both ways,
after both relaunch, after each phone changes network), `phone` (Wi-Fi → cellular → Wi-Fi, new
addresses in both families each time, a message sent while it has none), `suspend` and
`suspend-move` (frozen 60 s as iOS does a backgrounded app, waking on the same or a new network),
`frozen-relay` (the relay carrying two phones freezes; another helper exists), `redeem` (a link
through the inviter's own Mac, with her phone awake or asleep, or a friend's Mac), `carriers`
(three own devices carrying for a friend who is away: they must not pass it round).

The census (`census:link`, `census:helper`, `census:reply`): every pair in `CENSUS` side by side in
one lab, each redeemer adding its inviter by link, alone, with a public friend's relay, or as the app
does with a reply (the add in the background, and 5 s in, if it has not worked, a reply the inviter
opens). The path each pair is on
(read from both ends' packets: IPv6, IPv4 to a public address, IPv4 through a router's mapping,
IPv4 punched, LAN, VPN, through the helper), how soon it went direct, and after 10 minutes idle the
path, a message's latency and the packets a pair sent each other. The report leads with it.
`--no-mapping` takes port mapping off every router. `pinholes` measures how long each network keeps
an idle UDP flow (raw sockets, no peer); `reach:move` how soon the people around a phone have its
new addresses; `suspend10` a 10-minute sleep.
`freeze:10` and `freeze:40`: a friend frozen that long is written to, and a carrier must hold it in
seconds (the held connection is not idle yet). `failover:v6` and `failover:relay`: the selected path
dies under a working pair and nothing on the device notices (IPv6 dropped with IPv4 left; UDP between
them dropped with the relay left); a message 2 s later must arrive in seconds, and `-idle` watches
the path with nothing sent.
Real-network profiles, used by the census beside `upnp` and `home`: `cell-xlat` (cellular: IPv6
behind a firewall, IPv4 through a 464XLAT translator keeping one port per socket), `cell60`
(cellular: IPv6 behind a firewall, IPv4 a new port per destination), `cafe` (symmetric NAT),
`hotel` (UDP blocked), `home60`, `home120`, `cell30` (UDP forgotten after 60, 120, 30 s; both
cellular profiles also forget it after 60 s).

To add an environment, add a line to `ENVS` (and its rules in `router_script`); to add a
scenario, write a function returning rows and list it in `SCENARIOS`.
