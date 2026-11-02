#!/usr/bin/env python3
"""The peer network lab: real peer-node devices behind emulated routers, in Docker.

Every scenario builds its own small internet from scratch and tears it down after:

  core      the "internet": 7.7.7.0/24 and 2001:db8:ff::/64. A box that routes between sites
            and drops everything else, so nothing in the lab reaches the real network.
  site      a router (NAT, firewall, miniupnpd, netem) with a LAN behind it, or a public host.
  device    a container running `peer-node run`, driven over a FIFO; its stdout (events and the
            crate's JSON trace) is the container log, stamped by the Docker daemon's one clock.

Usage:
  lab.py build [--rev REV]              build peer-node for Linux from a clean worktree at REV
  lab.py run [--rev REV] [--only a,b]   run the matrix (or the named scenarios), write results/
  lab.py list                           list the scenarios
"""
import argparse
import datetime
import json
import os
import pathlib
import re
import statistics
import subprocess
import sys
import time

LAB = pathlib.Path(__file__).resolve().parent
REPO = LAB.parent
CACHE = pathlib.Path(os.environ.get("PEER_LAB_CACHE", "~/Library/Caches/peer-lab")).expanduser()
NODE_IMG, BUILD_IMG = "peer-lab-node", "peer-lab-build"
WAN4, WAN6 = "7.7.7", "2001:db8:ff"
CORE4, CORE6 = f"{WAN4}.2", f"{WAN6}::2"

# Where a device can be. `nat`: eim (one port per socket, replies only from where it sent:
# a typical home router), sym (a new random port per destination: carrier NAT); `outer` puts a
# second NAT in front; `v6`: none, fw (routed, no unsolicited inbound), open; `upnp`: igd
# (UPnP + NAT-PMP + PCP), pmp (NAT-PMP + PCP only), liar (grants, forwards nothing).
ENVS = {
    "pub":      dict(nat=None, v6="open", what="public address, no NAT"),
    "home":     dict(nat="eim", what="home router, no port mapping"),
    "upnp":     dict(nat="eim", upnp="igd", what="home router with UPnP, NAT-PMP and PCP"),
    "pmp":      dict(nat="eim", upnp="pmp", what="home router with NAT-PMP and PCP only"),
    "liar":     dict(nat="eim", upnp="liar", what="router that grants mappings and forwards nothing"),
    "cgnat":    dict(nat="sym", what="carrier NAT, a new port per destination"),
    "double":   dict(nat="eim", outer="sym", what="home router behind carrier NAT"),
    "v6home":   dict(nat="eim", v6="fw", what="home router, IPv6 with a stateful firewall"),
    "mobile":   dict(nat="sym", v6="fw", what="cellular: carrier NAT, IPv6 with a stateful firewall"),
    "v6open":   dict(nat="sym", v6="open", what="carrier NAT, IPv6 open inbound"),
    "udpblock": dict(nat="eim", udp=False, what="UDP blocked, TCP 80 and 443 only"),
    "lossy":    dict(nat="eim", netem="delay 150ms 50ms loss 10%", what="home router, 10% loss, 150 ms ± 50"),
    "short":    dict(nat="eim", udp_timeout=30, what="home router forgetting UDP after 30 s"),
    "bare":     dict(nat="eim", fw=False, what="home router with no firewall of its own: a stray packet to it renumbers a punch toward its sender"),
    # Real networks, as close as the lab gets. Cellular with 464XLAT/NAT64 is modelled as what an
    # app sees through it, a global IPv6 address behind a stateful firewall and IPv4 out through a
    # carrier translator keeping one port per socket (`cell-xlat`); other carriers put IPv4 behind
    # a carrier NAT with a new port per destination (`cell60`). A home network is `upnp` or `home`.
    "cell-xlat": dict(nat="eim", v6="fw", udp_timeout=60, what="cellular with 464XLAT: IPv6 behind a stateful firewall, IPv4 through the carrier's translator (one port per socket), UDP forgotten after 60 s"),
    "cell60":   dict(nat="sym", v6="fw", udp_timeout=60, what="cellular: IPv6 behind a stateful firewall, IPv4 behind carrier NAT (a new port per destination), UDP forgotten after 60 s"),
    "cafe":     dict(nat="sym", what="café Wi-Fi: symmetric NAT (a new port per destination), no IPv6, no mapping"),
    "hotel":    dict(nat="eim", udp=False, what="hotel Wi-Fi: UDP blocked, TCP 80 and 443 only, no IPv6"),
    "home60":   dict(nat="eim", udp_timeout=60, what="home router forgetting UDP after 60 s"),
    "home120":  dict(nat="eim", udp_timeout=120, what="home router forgetting UDP after 120 s"),
    "cell30":   dict(nat="sym", v6="fw", udp_timeout=30, what="cellular forgetting UDP after 30 s (carrier NAT and IPv6 firewall)"),
}

# Port mapping on every router that offers it (UPnP, NAT-PMP, PCP), or none at all (`--no-mapping`):
# every row that passes with mapping should pass without it.
MAPPING = os.environ.get("LAB_NO_MAPPING", "") == ""

# One-way delay on every link into the core, as on the real internet. With none (`--wan-delay 0`)
# the first side's packets always reach the other router before it has sent, and a Linux NAT
# then renumbers its port (an UNREPLIED conntrack entry for the router itself holds the tuple):
# the hardest case for a simultaneous punch, worth running too.
WAN_DELAY = os.environ.get("LAB_WAN_DELAY", "20ms")

# The numbers every build is held to (../DESIGN.md, "The network loop"), in seconds.
TARGET = {"meet": 10, "online": 2, "online-relayed": 5, "message": 1, "reconnect": 2, "offline": 60, "carried": 3, "recover": 5, "answer": 10}


def sh(args, check=True, timeout=600, input=None):
    r = subprocess.run(args, capture_output=True, text=True, timeout=timeout, input=input)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(map(str, args))}\n{r.stdout}\n{r.stderr}")
    return r.stdout


def short_rev(rev):
    return sh(["git", "-C", str(REPO), "rev-parse", "--short", rev]).strip()


def build(rev="HEAD"):
    """peer-node for Linux from a worktree at `rev`: uncommitted edits in the checkout never leak in."""
    rev = short_rev(rev)
    out = CACHE / "bin" / rev / "peer-node"
    if out.exists():
        return rev, out
    for img, df in ((NODE_IMG, "Dockerfile.node"), (BUILD_IMG, "Dockerfile.build")):
        if subprocess.run(["docker", "image", "inspect", img], capture_output=True).returncode != 0:
            sh(["docker", "build", "-q", "-t", img, "-f", str(LAB / df), str(LAB)], timeout=1800)
    wt = CACHE / "wt" / rev
    if not wt.exists():
        wt.parent.mkdir(parents=True, exist_ok=True)
        sh(["git", "-C", str(REPO), "worktree", "add", "--detach", str(wt), rev])
    vols = ["-v", f"{wt}:/src", "-v", "peer-lab-cargo:/usr/local/cargo/registry", "-v", "peer-lab-target:/target", "-e", "CARGO_TARGET_DIR=/target"]
    print(f"building peer-node at {rev} …", flush=True)
    sh(["docker", "run", "--rm", *vols, BUILD_IMG, "cargo", "build", "--release", "-p", "peer-node"], timeout=3600)
    out.parent.mkdir(parents=True, exist_ok=True)
    sh(["docker", "run", "--rm", "-v", "peer-lab-target:/target", "-v", f"{out.parent}:/out", BUILD_IMG, "cp", "/target/release/peer-node", "/out/"])
    return rev, out


def stamp(s):
    # "2026-10-16T03:52:29.000586123Z" → seconds
    return datetime.datetime.fromisoformat(s[:26] + "+00:00").timestamp()


class Box:
    def __init__(self, lab, name):
        self.lab, self.short, self.name = lab, name, f"plab-{lab.tag}-{name}"

    def sh(self, script, check=True, timeout=120):
        return sh(["docker", "exec", self.name, "sh", "-c", script], check=check, timeout=timeout)

    def logs(self):
        out = sh(["docker", "logs", "-t", self.name], check=False)
        lines = []
        for raw in out.splitlines():
            ts, _, line = raw.partition(" ")
            try:
                lines.append((stamp(ts), line))
            except ValueError:
                pass
        return lines

    def mark(self, what):
        """A line in this box's log, stamped by the daemon: the start of a measurement."""
        self.sh(f"echo '@mark {what}' >> /proc/1/fd/1")
        t0 = time.time()
        while time.time() - t0 < 10:
            for ts, line in reversed(self.logs()):
                if line == f"@mark {what}":
                    return ts
            time.sleep(0.1)
        raise RuntimeError(f"{self.short}: mark {what} never logged")


class Device(Box):
    def __init__(self, lab, site, name):
        super().__init__(lab, name)
        self.site, self.person = site, name.capitalize()

    def start(self, *flags, log=""):
        """`log`: a RUST_LOG filter, for iroh's own events (to the container log, as the trace)."""
        args = " ".join(["env", f"RUST_LOG={log}"] * bool(log) + ["peer-node", "--dir", "/data", "run", "--name", self.person, "--trace", *flags])
        self.sh(f"test -p /tmp/in || mkfifo /tmp/in; (exec 3<>/tmp/in; exec {args} <&3 >>/proc/1/fd/1 2>&1) &")
        self.wait(r"^online as ", since=0, timeout=20)
        self.id = re.search(r"device (\w+)", self.find(r"^online as ")[-1][1]).group(1)

    def leave(self):
        """Every address gone at once: off Wi-Fi, not yet on cellular (`Site.arrive`)."""
        sh(["docker", "network", "disconnect", self.net, self.name])

    def kill(self, sig="KILL"):
        self.sh(f"pkill -{sig} -x peer-node || true")
        time.sleep(0.3)

    def cmd(self, line):
        self.sh(f"printf '%s\\n' '{line}' > /tmp/in")

    def find(self, pattern, since=0):
        rx = re.compile(pattern)
        return [(ts, l) for ts, l in self.logs() if ts >= since and rx.search(l)]

    def wait(self, pattern, since, timeout):
        end = time.time() + timeout
        while time.time() < end:
            hits = self.find(pattern, since)
            if hits:
                return hits[0]
            time.sleep(0.2)
        return None

    def traces(self, ev, since=0):
        out = []
        for ts, l in self.logs():
            if ts >= since and l.startswith("{") and f'"ev":"{ev}"' in l:
                try:
                    out.append((ts, json.loads(l)))
                except json.JSONDecodeError:
                    pass
        return out

    def invite(self):
        t = self.mark("invite")
        self.cmd("invite")
        hit = self.wait(r"^invite: ", t, 10)
        return hit[1].split("invite: ", 1)[1].strip() if hit else None

    def online_seen(self, other, since, timeout):
        """When `other` came online here: (seconds after since, the path words) or None. A contact
        is printed by name, a co-member by device id alone."""
        hit = self.wait(rf"^· online (?:\S+'s )?{other.id}\b", since, timeout)
        if not hit:
            return None
        return hit[0] - since, hit[1].split(other.id, 1)[1].strip()

    def back(self, other, since, timeout):
        """When a connection to `other` was held again after `since`: an online event, or the
        crate's own trace of a dial that worked, an attach, a redial or a migration (a connection
        kept or replaced in place prints no offline/online pair). (seconds, how) or None."""
        end = time.time() + timeout
        rx = re.compile(rf"^· online (?:\S+'s )?{other.id}\b")
        while time.time() < end:
            for ts, l in self.logs():
                if ts < since:
                    continue
                if rx.search(l):
                    return ts - since, l.split(other.id, 1)[1].strip()
                if l.startswith("{") and f'"device":"{other.id}"' in l and ('"ev":"attach"' in l or '"ev":"redialed"' in l or ('"ev":"migrated"' in l) or ('"ev":"dial"' in l and '"ok":true' in l)):
                    path = re.search(r'"path":"([^"]*)"', l)
                    return ts - since, path.group(1) if path else ""
            time.sleep(0.2)
        return None

    def path_to(self, other):
        """The path as the crate says it, and the wire the packets actually take (6 s of capture
        while a message goes, if `other` is a contact)."""
        t = self.mark(f"peers-{other.short}")
        self.cmd("peers")
        hit = self.wait(rf"^{other.id} (online|offline) ", t, 5)
        words = hit[1].split(" ", 2)[2] if hit else "unknown"
        if hit and hit[1].split(" ")[1] == "offline":
            return "offline", words
        self.sh("(timeout 6 tcpdump -nn -l -i any '(udp or tcp) and not port 5353 and not port 1900 and not port 5351 and not port 5000' > /tmp/cap 2>/dev/null &) ; true")
        time.sleep(0.5)
        self.cmd(f"post {other.person} wire")
        time.sleep(6)
        mine, counts = self.addrs(), {}
        for line in self.sh("cat /tmp/cap", check=False).splitlines():
            m = re.search(r" (IP6?) (\S+) > (\S+): ", line)
            if not m:
                continue
            fam, a, b = m.groups()
            remote = b if any(a.rsplit(".", 1)[0] == x for x in mine) else a
            proto = "TCP" if "Flags" in line else "UDP"
            key = ("IPv6" if fam == "IP6" else "IPv4", proto, remote.rsplit(".", 1)[0])
            counts[key] = counts.get(key, 0) + 1
        if not counts:
            return "no packets", words
        # A direct path is UDP; TCP is a relay (the home relay's keepalives run beside a direct
        # path, so only UDP is counted when the crate says direct, and not to a third device:
        # a go-between or a relay talks with us beside it).
        third = {a for d in self.lab.boxes if isinstance(d, Device) and d not in (self, other) for a in d.addrs()}
        udp = {k: v for k, v in counts.items() if k[1] == "UDP" and k[2] not in third}
        pool = udp if words.startswith("direct") and udp else counts
        fam, proto, remote = max(pool, key=pool.get)
        return f"{fam} {proto} to {remote}", words

    def addrs(self):
        if not hasattr(self, "_addrs"):
            self._addrs = [a.split("/")[0] for a in self.sh("ip -o addr | awk '{print $4}'").split()]
        return self._addrs


class Site:
    """A router with a LAN behind it, or (`pub`) a place on the core network itself."""

    def __init__(self, lab, kind):
        self.lab, self.kind, self.env = lab, kind, ENVS[kind]
        lab.k += 1
        self.k = k = lab.k
        self.devices = 0
        if self.env["nat"] is None:
            self.router, self.public_ip = None, None
            return
        v6 = self.env.get("v6")
        self.lan = lab.network(f"lan{k}", f"10.{k}.0.0/24", f"2001:db8:{k}::/64" if v6 else None)
        sys_r = ["net.ipv4.ip_forward=1", "net.ipv6.conf.all.forwarding=1"]
        if self.env.get("udp_timeout"):
            sys_r += [f"net.netfilter.nf_conntrack_udp_timeout={self.env['udp_timeout']}", f"net.netfilter.nf_conntrack_udp_timeout_stream={self.env['udp_timeout']}"]
        outer = self.env.get("outer")
        if outer:
            # Two NATs: the home router's "internet" is the carrier's network.
            self.cg = lab.network(f"cg{k}", f"100.64.{k}.0/24")
            self.outer = lab.box(f"cg{k}", lab.wan, f"{WAN4}.{100 + k}", f"{WAN6}::{100 + k:x}", sysctls=sys_r)
            lab.connect(self.outer, self.cg, f"100.64.{k}.254")
            self.outer.sh(router_script(f"{WAN4}.{100 + k}", f"100.64.{k}.254", nat=outer, default4=CORE4, default6=CORE6))
            self.router = lab.box(f"r{k}", self.cg, f"100.64.{k}.2", None, sysctls=sys_r)
            wan_ip, d4 = f"100.64.{k}.2", f"100.64.{k}.254"
            self.public_ip = f"{WAN4}.{100 + k}"
        else:
            self.router = lab.box(f"r{k}", lab.wan, f"{WAN4}.{100 + k}", f"{WAN6}::{100 + k:x}", sysctls=sys_r)
            wan_ip, d4 = f"{WAN4}.{100 + k}", CORE4
            self.public_ip = wan_ip
        lab.connect(self.router, self.lan, f"10.{k}.0.254", f"2001:db8:{k}::fe" if v6 else None)
        self.router.sh(router_script(wan_ip, f"10.{k}.0.254", nat=self.env["nat"], default4=d4, default6=CORE6 if not outer else None,
                                     v6=v6, udp=self.env.get("udp", True), netem=self.env.get("netem"), upnp=self.env.get("upnp") if MAPPING else None, fw=self.env.get("fw", True)))
        if v6:
            lab.v6_routes.append((f"2001:db8:{k}::/64", f"{WAN6}::{100 + k:x}"))

    def device(self, name):
        self.devices += 1
        n = 10 + self.devices
        if self.router is None:
            n = 10 + self.lab.public
            self.lab.public += 1
            d = self.lab.device(self, name, self.lab.wan, f"{WAN4}.{n}", f"{WAN6}::{n:x}")
            d.sh(f"ip route replace default via {CORE4}; ip -6 route replace default via {CORE6}" + (f"; tc qdisc add dev eth0 root netem delay {WAN_DELAY}" if WAN_DELAY else ""))
            d.net = self.lab.wan
            d.ip4, d.ip6 = f"{WAN4}.{n}", f"{WAN6}::{n:x}"
        else:
            v6 = self.env.get("v6")
            d = self.lab.device(self, name, self.lan, f"10.{self.k}.0.{n}", f"2001:db8:{self.k}::{n:x}" if v6 else None)
            d.sh(f"ip route replace default via 10.{self.k}.0.254" + (f"; ip -6 route replace default via 2001:db8:{self.k}::fe" if v6 else ""))
            d.net = self.lan
            d.ip4, d.ip6 = f"10.{self.k}.0.{n}", (f"2001:db8:{self.k}::{n:x}" if v6 else None)
        return d

    def arrive(self, d, route=True):
        """`d` joins this LAN at fresh addresses in both families (after `leave`): a phone moving
        between Wi-Fi and cellular gets new ones every time. `route=False` (a frozen device can
        run nothing): call `route(d)` once it runs."""
        self.devices += 1
        n = 60 + self.devices
        v6 = self.env.get("v6")
        self.lab.connect(d, self.lan, f"10.{self.k}.0.{n}", f"2001:db8:{self.k}::{n:x}" if v6 else None)
        d.net = self.lan
        if route:
            self.route(d)

    def route(self, d):
        v6 = self.env.get("v6")
        d.sh(f"ip route replace default via 10.{self.k}.0.254" + (f"; ip -6 route replace default via 2001:db8:{self.k}::fe" if v6 else ""))

    def reboot(self):
        """The router restarts: every NAT mapping and conntrack entry goes, miniupnpd forgets."""
        for r in [x for x in (getattr(self, "outer", None), self.router) if x]:
            r.sh("conntrack -F 2>/dev/null; pkill -x miniupnpd; iptables -t nat -F MINIUPNPD 2>/dev/null; iptables -F MINIUPNPD 2>/dev/null; "
                 "if [ -f /etc/lab-upnp.conf ]; then miniupnpd -f /etc/lab-upnp.conf; fi; true")


def router_script(wan_ip, lan_ip, nat, default4, default6=None, v6=None, udp=True, netem=None, upnp=None, fw=True):
    s = [
        "set -e",
        f"WAN=$(ip -o -4 addr | awk '$4 ~ /^{wan_ip}\\// {{print $2}}')",
        f"LAN=$(ip -o -4 addr | awk '$4 ~ /^{lan_ip}\\// {{print $2}}')",
        f"ip route replace default via {default4} dev $WAN",
    ]
    if default6:
        s.append(f"ip -6 route replace default via {default6} dev $WAN")
    s.append("iptables -t nat -A POSTROUTING -o $WAN -j MASQUERADE" + (" --random-fully" if nat == "sym" else ""))
    if fw:
        # A router's own firewall: nothing unsolicited from the WAN reaches the router itself.
        # Dropped, a stray packet leaves no conntrack entry; accepted (`bare`), it holds the tuple
        # and the router renumbers a punch from inside toward its sender.
        s += ["iptables -A INPUT -i $WAN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT", "iptables -A INPUT -i $WAN -j DROP"]
    if not udp:
        s += ["iptables -A FORWARD -i $LAN -p udp -j DROP", "iptables -A FORWARD -i $LAN -p tcp -m multiport ! --dports 80,443 -j DROP",
              "ip6tables -A FORWARD -i $LAN -p udp -j DROP", "ip6tables -A FORWARD -i $LAN -p tcp -m multiport ! --dports 80,443 -j DROP"]
    if v6 == "fw":
        s += ["ip6tables -A FORWARD -i $WAN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT", "ip6tables -A FORWARD -i $WAN -j DROP"]
    if netem or WAN_DELAY:
        s.append(f"tc qdisc add dev $WAN root netem {netem or 'delay ' + WAN_DELAY}")
    if upnp:
        # The chains miniupnpd writes to; a liar's are never hooked in, so what it grants goes nowhere.
        s += ["iptables -t nat -N MINIUPNPD", "iptables -t nat -N MINIUPNPD-POSTROUTING", "iptables -t mangle -N MINIUPNPD", "iptables -N MINIUPNPD"]
        if upnp != "liar":
            s += ["iptables -t nat -I PREROUTING -i $WAN -j MINIUPNPD", "iptables -t nat -I POSTROUTING -o $WAN -j MINIUPNPD-POSTROUTING",
                  "iptables -t mangle -I PREROUTING -i $WAN -j MINIUPNPD", "iptables -I FORWARD -i $WAN ! -o $WAN -j MINIUPNPD"]
        s += [
            "cat > /etc/lab-upnp.conf <<EOF",
            "ext_ifname=$WAN", "listening_ip=$LAN", "port=5000",
            f"enable_upnp={'no' if upnp == 'pmp' else 'yes'}", "enable_natpmp=yes", "secure_mode=no", "system_uptime=yes",
            "uuid=3d3cec3a-8cf0-11e0-98ee-001a6bd2d07b", "allow 1024-65535 10.0.0.0/8 1024-65535", "deny 0-65535 0.0.0.0/0 0-65535",
            "EOF",
            "miniupnpd -f /etc/lab-upnp.conf",
        ]
    return "\n".join(s)


class Lab:
    def __init__(self, binary, logdir, tag):
        self.binary, self.logdir, self.tag = binary, logdir, tag
        self.k, self.public, self.nets, self.boxes, self.v6_routes = 0, 0, [], [], []
        self.wan = self.network("wan", f"{WAN4}.0/24", f"{WAN6}::/64")
        self.core = self.box("core", self.wan, CORE4, CORE6, sysctls=["net.ipv4.ip_forward=1", "net.ipv6.conf.all.forwarding=1"])
        # No default route: whatever is not a lab site goes nowhere.
        self.core.sh("ip route del default 2>/dev/null; ip -6 route del default 2>/dev/null; true")

    def network(self, name, v4, v6=None):
        full = f"plab-{self.tag}-{name}"
        gw4 = v4.rsplit(".", 1)[0] + ".1"
        # No masquerade: Docker's per-network rule would rewrite the source of every packet
        # leaving this subnet, bridged ones included (br_netfilter), so a LAN device would see
        # the whole lab "internet" as its bridge gateway. It is also one less way out of the lab.
        args = ["docker", "network", "create", "-o", "com.docker.network.bridge.enable_ip_masquerade=false", "--subnet", v4, "--gateway", gw4]
        if v6:
            args += ["--ipv6", "--subnet", v6, "--gateway", v6.split("/")[0] + "1"]
        sh(args + [full])
        self.nets.append(full)
        return full

    def box(self, name, net, ip, ip6=None, sysctls=(), cls=Box, **kw):
        b = cls(self, name, **kw) if cls is Box else cls(self, kw.pop("site"), name)
        args = ["docker", "run", "-d", "--name", b.name, "--hostname", name, "--cap-add", "NET_ADMIN", "--cap-add", "NET_RAW",
                "--network", net, "--ip", ip, "--sysctl", "net.ipv6.conf.all.disable_ipv6=0",
                "-v", f"{self.binary}:/usr/local/bin/peer-node:ro"]
        if ip6:
            args += ["--ip6", ip6]
        for s in sysctls:
            args += ["--sysctl", s]
        sh(args + [NODE_IMG])
        self.boxes.append(b)
        return b

    def connect(self, box, net, ip, ip6=None):
        args = ["docker", "network", "connect", "--ip", ip]
        if ip6:
            args += ["--ip6", ip6]
        sh(args + [net, box.name])

    def device(self, site, name, net, ip, ip6):
        return self.box(name, net, ip, ip6, cls=Device, site=site)

    def site(self, kind):
        return Site(self, kind)

    def ready(self):
        """Every site's IPv6 LAN is routed by the core."""
        for prefix, via in self.v6_routes:
            self.core.sh(f"ip -6 route replace {prefix} via {via}")

    def teardown(self):
        self.logdir.mkdir(parents=True, exist_ok=True)
        for b in self.boxes:
            try:
                (self.logdir / f"{b.short}.log").write_text("\n".join(f"{ts:.3f} {l}" for ts, l in b.logs()))
            except Exception:
                pass
        sh(["docker", "rm", "-f", *[b.name for b in self.boxes]], check=False)
        # A network still detaching a container refuses removal for a moment; left, it collides
        # with the next scenario's address pool.
        for n in self.nets:
            for _ in range(5):
                if subprocess.run(["docker", "network", "rm", n], capture_output=True).returncode == 0:
                    break
                time.sleep(1)


# ---------------------------------------------------------------- scenarios

class Row(dict):
    pass


def row(scenario, env, ok, secs=None, path="", target=None, note=""):
    if secs is None:
        verdict = "FAIL" if ok is False else ("n/a" if ok is None else "pass")
    else:
        verdict = "pass" if ok and (target is None or secs <= target) else ("SLOW" if ok else "FAIL")
    return Row(scenario=scenario, env=env, result=verdict, secs=secs, path=path, target=target, note=note)


def befriend(a, b, timeout=25):
    """b redeems a's invite. Returns (seconds to `added`, error or None)."""
    link = a.invite()
    if not link:
        return None, "no invite printed"
    t = b.mark("add")
    b.cmd(f"add {link}")
    hit = b.wait(r"^(added |add failed: |error: )", t, timeout)
    if not hit:
        return None, "no answer"
    if not hit[1].startswith("added "):
        return None, hit[1]
    return hit[0] - t, None


def befriend_reply(a, b, timeout=40):
    """b redeems a's invite as an app does: the add in the background, and 5 s in, if it has not
    worked, a reply (`Peer::reply`) that a opens. Returns (seconds to b's contact, "link" or
    "reply", error or None)."""
    link = a.invite()
    if not link:
        return None, "link", "no invite printed"
    t = b.mark("add")
    b.cmd(f"add-bg {link}")
    hit = b.wait(r"^added ", t, 5)
    if hit:
        return hit[0] - t, "link", None
    t2 = b.mark("reply")
    b.cmd(f"reply {link}")
    r = b.wait(r"^(reply: |error: )", t2, 10)
    if not r or not r[1].startswith("reply: "):
        return None, "reply", r[1] if r else "no reply printed"
    a.cmd(f"add {r[1].split('reply: ', 1)[1].strip()}")
    hit = b.wait(r"^(added |· replied )", t, timeout)
    if not hit:
        theirs = a.find(r"^(add failed: |error: )", t2)
        return None, "reply", theirs[-1][1] if theirs else "no answer"
    return hit[0] - t, "reply", None


# How a contact is written to: `post` (an envelope, the crate's own carrying), or `send` (as baud
# does: on a cached app connection, counted once the far side has it, else to carriers).
SAY = "post"


def sends(lab, fn, *params):
    """`fn` with every message to a contact sent as baud sends it."""
    global SAY
    SAY = "send"
    try:
        return fn(lab, *params)
    finally:
        SAY = "post"


def tell(src, dst, text):
    src.cmd(f"{SAY} {dst.person} {text}")


def say(src, dst, text, g=None, since=None, timeout=20):
    """`src` writes `text` to `dst`: in group `g` (contact or not), else to a contact (`SAY`).
    Seconds from `since` (else the write) until `dst` has it, or None."""
    t = src.mark(f"say-{text}")
    if g:
        src.cmd(f"gpost {g} {dst.person} {text}")
    else:
        tell(src, dst, text)
    hit = dst.wait(rf'^· inbox \w+: "{text}"', t, timeout)
    return (hit[0] - (since or t)) if hit else None


def relay_offered(d, timeout=30):
    return d.wait(r'"ev":"relay".*"offered":true', 0, timeout)


def group(maker, kind, members):
    """`maker` makes a `kind` group and adds `members` (its contacts); each keeps it and adds the
    maker, as the app does; returns the group id once every member lists every other, or None."""
    t = maker.mark("group")
    maker.cmd(f"group-new {kind}")
    hit = maker.wait(r"^group \w+ (Space|Chat)", t, 10)
    if not hit:
        return None
    g = hit[1].split()[1]
    for x in members:
        maker.cmd(f"group-add {g} {x.person}")
    time.sleep(1)
    for x in members:
        x.cmd(f"group {g} {kind}")
        x.cmd(f"group-add {g} {maker.person}")
    end = time.time() + 20
    while time.time() < end:
        ok = True
        for x in members:
            t = x.mark("members")
            x.cmd(f"members {g}")
            time.sleep(0.5)
            listed = {l.split()[1] for _, l in x.find(r"^member ", t)}
            ok &= all(y.person in listed for y in members if y is not x)
        if ok:
            return g
        time.sleep(1)
    return None


def link_devices(old, new):
    """`new` becomes another device of `old`'s person (old started with --auto-confirm-links)."""
    t = old.mark("link-device")
    old.cmd("link-device")
    hit = old.wait(r"^device link: ", t, 10)
    if not hit:
        return "no device link"
    t = new.mark("link")
    new.cmd(f"link {hit[1].split('device link: ', 1)[1].strip()}")
    got = new.wait(r"^(linked: |error: |link failed)", t, 30)
    return None if got and got[1].startswith("linked: ") else (got[1] if got else "no answer")


def message(src, dst, text="ping"):
    t = src.mark(f"post-{text}")
    src.cmd(f"post {dst.person} {text}")
    hit = dst.wait(rf'^· inbox \w+: "{text}"', t, 20)
    return (hit[0] - t) if hit else None


def scenario_pair(lab, ea, eb, relay=False, invite_after=0, tailnet=False):
    """Two strangers: a (ea) invites, b (eb) redeems; a message; the path after 8 s; both relaunch.
    `relay`: a relay friend in the circle, on a public address (True) or behind a site's router
    (its env), offered at its mapped address and its LAN one. `tailnet`: a and b are also on one
    Tailscale-style VPN (100.100.0.0/24, inside the 100.64/10 range Tailscale uses)."""
    behind = relay if isinstance(relay, str) else None
    rows, env = [], f"{ea} ← {eb}" + (f" + relay friend behind {behind}" if behind else " + relay friend" if relay else "") + (f", invite {invite_after} s after launch" if invite_after else "") + (", one tailnet" if tailnet else "")
    sa, sb = lab.site(ea), lab.site(eb)
    r = None
    if relay:
        r = lab.site(behind or "pub").device("rex")
    a, b = sa.device("ana"), sb.device("bo")
    if tailnet:
        net = lab.network("tailnet", "100.100.0.0/24")
        lab.connect(a, net, "100.100.0.11")
        lab.connect(b, net, "100.100.0.12")
    lab.ready()
    if behind:
        # On its own port (the router maps no port under 1024), offered once the router maps it.
        r.start("--relay")
        if not r.wait(r'"ev":"portmap".*"proto":"tcp"', 0, 30):
            return [row("relay friend mapped", env, False, note="no tcp mapping")]
    elif r:
        r.start("--relay", "--port", "443", "--public")
    a.start()
    b.start()
    if r:
        # Behind a liar, the friend's own link names a relay nobody reaches (and nobody is there
        # yet to tell it so): it redeems ana's instead.
        secs, err = befriend(a, r) if behind == "liar" else befriend(r, a)
        if err:
            return [row("meet relay friend", env, False, note=err)]
        a.wait(r"^· online Rex's ", 0, 15)
        if behind:
            # Its probe asks ana, who sees it across the internet, to dial back to its mappings.
            r.wait(r'"ev":"checked".*"proto":"tcp"', 0, 15)
    time.sleep(invite_after)
    secs, err = befriend(a, b)
    rows.append(row("meet by link", env, err is None, secs, target=TARGET["meet"], note=err or ""))
    if err:
        return rows
    seen = a.online_seen(b, 0, 15)
    time.sleep(8)  # room for a punch to replace a relayed path
    wire, words = a.path_to(b)
    rows.append(row("path after 8 s", env, None if seen else False, path=f"{words} · {wire}"))
    secs = message(b, a, "hello")
    rows.append(row("message", env, secs is not None, secs, target=TARGET["message"]))
    # Both quit hard and come back: each dials the other from its records.
    a.kill(); b.kill()
    t = a.mark("relaunch")
    a.start(); b.start()
    got = a.back(b, t, 30)
    rows.append(row("reconnect after both relaunch", env, got is not None, got[0] if got else None,
                    path=got[1] if got else "", target=TARGET["reconnect"]))
    if behind:
        # Away from the friend's LAN, its LAN relay URL answers nothing: no dial or home set names it.
        lan = rf"http://10\.{r.site.k}\.0\."
        named = [l for x in (a, b) for _, l in x.find(rf'"ev":"(dial|home)".*{lan}')]
        rows.append(row("friend's LAN relay URL left out away from its LAN", env, not named,
                        note=f"named by {len(named)} dials or home sets" if named else ""))
    return rows


def scenario_introduce(lab, ea, eb, relay=False):
    """Two devices behind NATs who never met: a friend on a public address (no relay unless
    `relay`) puts both in a space, so they are mutuals; they must connect to each other."""
    env = f"{ea} ↔ {eb} via a public friend" + (" with a relay" if relay else "")
    sm = lab.site("pub")
    m = sm.device("mia")
    a, b = lab.site(ea).device("ana"), lab.site(eb).device("bo")
    lab.ready()
    m.start(*(["--relay", "--port", "443", "--public"] if relay else []))
    a.start(); b.start()
    for x in (a, b):
        secs, err = befriend(m, x)
        if err:
            return [row("introduction", env, False, note=f"meeting the friend: {err}")]
    t = m.mark("space")
    m.cmd("group-new space")
    hit = m.wait(r"^group \w+ Space", t, 10)
    if not hit:
        return [row("introduction", env, False, note="no space")]
    g = hit[1].split()[1]
    # The app's order: mia adds both (her lists reach them before they keep the group, and are
    # refused), then each keeps the space and its maker, as on the membership event; mia answers
    # each with her whole list, so the two learn each other and are mutuals.
    m.cmd(f"group-add {g} Ana")
    m.cmd(f"group-add {g} Bo")
    time.sleep(1)  # each person accepts; the clock starts when they do
    t = a.mark("joined")
    for x in (a, b):
        x.cmd(f"group {g} space")
        x.cmd(f"group-add {g} Mia")
    got = a.back(b, t, 45)
    intro = len(a.traces("introduce", t)) + len(b.traces("introduce", t))
    punched = len(a.traces("punch", t)) + len(b.traces("punch", t))
    note = f"introductions asked {intro}, punches answered {punched}"
    if not got:
        return [row("mutuals connect", env, False, note=note)]
    time.sleep(6)
    wire, words = a.path_to(b)
    return [row("mutuals connect", env, True, got[0], path=f"{words} · {wire}", target=TARGET["online-relayed" if relay else "online"], note=note)]


def scenario_dynamics(lab, ea, eb, event):
    """One thing happens to a working pair (a in ea dialed b in eb): `wake` (a frozen 30 s),
    `move` (a moves to a carrier NAT), `reboot` (b's router restarts), `dead` (a killed), `idle`
    (75 s of silence)."""
    env = f"{ea} → {eb}"
    sa, sb = lab.site(ea), lab.site(eb)
    other = lab.site("cgnat") if event == "move" else None
    a, b = sa.device("ana"), sb.device("bo")
    lab.ready()
    b.start(); a.start()
    secs, err = befriend(b, a)
    if err or not a.online_seen(b, 0, 15):
        return [row(event, env, False, note=f"setup: {err or 'never online'}")]
    time.sleep(3)
    if event == "wake":
        sh(["docker", "pause", a.name])
        time.sleep(30)
        t = b.mark("unpause")
        sh(["docker", "unpause", a.name])
        got = a.back(b, t, 40)
        return [row("reconnect after 30 s asleep", env, got is not None, got[0] if got else None, path=got[1] if got else "", target=TARGET["reconnect"])]
    if event == "move":
        t = a.mark("move")
        sh(["docker", "network", "disconnect", sa.lan if sa.router else lab.wan, a.name])
        lab.connect(a, other.lan, f"10.{other.k}.0.99")
        a.sh(f"ip route replace default via 10.{other.k}.0.254")
        got = a.back(b, t, 60)
        return [row("reconnect after a network move", env + " ⇒ cgnat", got is not None, got[0] if got else None, path=got[1] if got else "", target=TARGET["reconnect"])]
    if event == "reboot":
        mapped = [tr for _, tr in b.traces("portmap", 0)]
        port = mapped[-1]["external"].rsplit(":", 1)[1] if mapped else None
        t0 = time.time()
        t = a.mark("reboot")
        sb.reboot()
        # When the router holds b's port again (its own table: an unchanged mapping prints nothing).
        remapped = None
        if port:
            while time.time() - t0 < 120 and remapped is None:
                if f"dpt:{port} " in sb.router.sh("iptables -t nat -L MINIUPNPD -n", check=False) + " ":
                    remapped = time.time() - t0
                else:
                    time.sleep(2)
        secs = message(a, b, "after-reboot")
        if secs is None:
            got = a.back(b, t, 240)
            secs = message(a, b, "later") if got else None
        took = time.time() - t0 if secs is not None else None
        note = (f"b's port held again after {remapped:.0f} s" if remapped is not None else "b's port never held again") + (" (no mapping before)" if not port else "")
        return [row("message after b's router reboots", env, secs is not None, took, target=TARGET["reconnect"], note=note)]
    if event == "dead":
        t = b.mark("dead")
        a.kill()
        hit = b.wait(r"^· offline (?:\S+'s )?" + a.id, t, 75)
        return [row("dead peer seen offline", env, hit is not None, (hit[0] - t) if hit else None, target=TARGET["offline"])]
    if event == "idle":
        t = a.mark("idle")
        time.sleep(75)
        dropped = a.find(rf"^· offline (?:\S+'s )?{b.id}", t)
        secs = message(b, a, "after-idle")
        return [row("message after 75 s idle", env, secs is not None, secs, target=TARGET["message"], note="dropped while idle" if dropped else "held while idle")]
    raise ValueError(event)


def scenario_meeting_moves(lab, e_from, e_to):
    """A device runs the relay where its router maps the port, then moves somewhere it can't:
    it must stop naming itself as the meeting device and offering the relay."""
    env = f"relay host {e_from} ⇒ {e_to}"
    s1, s2 = lab.site(e_from), lab.site(e_to)
    h = s1.device("hal")
    f = lab.site("home").device("fay")
    lab.ready()
    h.start("--relay", "--port", "4433")
    f.start()
    befriend(h, f)
    def meeting():
        t = h.mark("meeting")
        h.cmd("meeting")
        hit = h.wait(r"^meeting: ", t, 5)
        return hit[1] if hit else "?"
    t0 = time.time()
    while time.time() - t0 < 30 and "Own" not in meeting():
        time.sleep(2)
    before = meeting()
    t = h.mark("move")
    sh(["docker", "network", "disconnect", s1.lan, h.name])
    lab.connect(h, s2.lan, f"10.{s2.k}.0.98")
    h.sh(f"ip route replace default via 10.{s2.k}.0.254")
    time.sleep(40)
    after = meeting()
    return [row("meeting device after moving off its mapped network", env, None if "Own" not in before else not ("Own" in after),
                note=f"before: {before} · 40 s after the move: {after}")]


def peer_words(x, y):
    """How `x` says it reaches `y` (`peers`), contact or co-member."""
    t = x.mark(f"peers-{y.short}")
    x.cmd("peers")
    hit = x.wait(rf"^{y.id} (online|offline) ", t, 5)
    return hit[1].split(" ", 1)[1] if hit else "unknown"


def scenario_circle(lab, ea, eb, kind, ec="upnp"):
    """The demo. Jo (ea) and Sam (eb) are each Carl's contacts, and Carl's Mac (ec) runs a
    relay. `chat`: Carl puts them in a chat (they stay strangers to each other; Carl carries).
    `space`: a space (they become mutuals). `contacts`: Sam adds Jo by a link through Carl's
    relay. Messages both ways, after both relaunch, and after each phone changes network."""
    env = f"{ea} ↔ {eb}, {kind}, Carl's Mac {ec}"
    sc, sa, sb = lab.site(ec), lab.site(ea), lab.site(eb)
    cells = [lab.site("mobile"), lab.site("mobile")]
    c, a, b = sc.device("carl"), sa.device("jo"), sb.device("sam")
    lab.ready()
    c.start("--relay", *(["--public", "--port", "443"] if ec == "pub" else []))
    if not relay_offered(c):
        return [row("Carl's relay offered", env, False)]
    a.start(); b.start()
    for x in (a, b):
        secs, err = befriend(c, x)
        if err or not x.wait(r"^· online Carl's ", 0, 15):
            return [row(f"{x.person} meets Carl", env, False, note=err or "never online")]
    g = None
    t0 = a.mark("joined")
    if kind == "contacts":
        secs, err = befriend(a, b)
        if err:
            return [row("Sam adds Jo through Carl's relay", env, False, note=err)]
    else:
        g = group(c, kind, [a, b])
        if not g:
            return [row(f"{kind} formed", env, False, note="the members never listed each other")]
    rows = []
    if kind != "chat":
        got = a.back(b, t0, 30)
        rows.append(row("connected", env, got is not None, got[0] if got else None, path=peer_words(a, b), target=TARGET["online-relayed"]))

    def both(label, since, target, timeout=30):
        for src, dst in ((a, b), (b, a)):
            secs = say(src, dst, f"m{len(rows)}", g, since, timeout)
            rows.append(row(f"{label}: {src.person} → {dst.person}", env, secs is not None, secs, target=TARGET[target]))

    both("message", None, "carried")
    a.kill(); b.kill()
    t = a.mark("relaunch")
    a.start(); b.start()
    both("after both relaunch", t, "recover", 40)
    for x, cell in ((a, cells[0]), (b, cells[1])):
        x.leave()
        time.sleep(2)
        t = x.mark("arrive")
        cell.arrive(x)
        both(f"after {x.person}'s phone changes network", t, "recover", 40)
    return rows


def scenario_phone(lab, via):
    """Pia's phone on Wi-Fi with Bo, `direct` (Bo's router maps a port) or `relay` (Bo behind
    carrier NAT; Carl's Mac relays). Wi-Fi → cellular → Wi-Fi, all-new addresses each time, Bo
    posting to Pia while her phone has none: each must recover in seconds, without a restart."""
    env = f"phone v6home ⇄ mobile, {via}"
    wifi, cell = lab.site("v6home"), lab.site("mobile")
    sb = lab.site("upnp" if via == "direct" else "cgnat")
    c = lab.site("upnp").device("carl") if via == "relay" else None
    p, b = wifi.device("pia"), sb.device("bo")
    lab.ready()
    if c:
        c.start("--relay")
        if not relay_offered(c):
            return [row("Carl's relay offered", env, False)]
    p.start(); b.start()
    for x in [x for x in (p, b) if c]:
        secs, err = befriend(c, x)
        if err or not x.wait(r"^· online Carl's ", 0, 15):
            return [row(f"{x.person} meets Carl", env, False, note=err or "never online")]
    secs, err = befriend(b, p)
    if err or not p.online_seen(b, 0, 15):
        return [row("Pia adds Bo", env, False, note=err or "never online")]
    time.sleep(3)
    rows = [row("connected", env, None, path=peer_words(p, b))]
    for n, (to, label) in enumerate(((cell, "Wi-Fi → cellular"), (wifi, "cellular → Wi-Fi"))):
        p.leave()
        tell(b, p, f"gap{n}")
        time.sleep(2)
        t = p.mark("arrive")
        to.arrive(p)
        hit = p.wait(rf'^· inbox \w+: "gap{n}"', t, 40)
        rows.append(row(f"{label}: Bo's message from while it had no network", env, hit is not None, (hit[0] - t) if hit else None, target=TARGET["recover"]))
        secs = say(p, b, f"after{n}", None, t, 40)
        rows.append(row(f"{label}: Pia → Bo", env, secs is not None, secs, target=TARGET["recover"], path=peer_words(p, b)))
    return rows


def scenario_suspend(lab, via, moves=False, asleep=60):
    """Pia's phone on cellular with Bo, `direct` (Bo's router maps a port) or `relay` (Bo behind
    carrier NAT; Carl's Mac relays): suspended 60 s, as iOS does an app in the background, while Bo
    posts to it. Within seconds of resuming it must have the message and be able to answer."""
    env = f"phone mobile, suspended {asleep} s, {via}" + (", wakes on Wi-Fi" if moves else "")
    sp = lab.site("mobile")
    lab_wifi = lab.site("v6home") if moves else None
    sb = lab.site("upnp" if via == "direct" else "cgnat")
    c = lab.site("upnp").device("carl") if via == "relay" else None
    p, b = sp.device("pia"), sb.device("bo")
    lab.ready()
    if c:
        c.start("--relay")
        if not relay_offered(c):
            return [row("Carl's relay offered", env, False)]
    p.start(); b.start()
    for x in [x for x in (p, b) if c]:
        secs, err = befriend(c, x)
        if err or not x.wait(r"^· online Carl's ", 0, 15):
            return [row(f"{x.person} meets Carl", env, False, note=err or "never online")]
    secs, err = befriend(b, p)
    if err or not p.online_seen(b, 0, 15):
        return [row("Pia adds Bo", env, False, note=err or "never online")]
    time.sleep(3)
    sh(["docker", "pause", p.name])
    time.sleep(5)
    tell(b, p, "asleep")
    time.sleep(asleep - 5)
    if moves:
        # Asleep, it went from cellular onto Wi-Fi: it wakes to all-new addresses.
        p.leave()
        lab_wifi.arrive(p, route=False)
    t = b.mark("resume")
    sh(["docker", "unpause", p.name])
    if moves:
        lab_wifi.route(p)
    hit = p.wait(r'^· inbox \w+: "asleep"', t, 40)
    rows = [row("Bo's message from while it slept", env, hit is not None, (hit[0] - t) if hit else None, target=TARGET["recover"])]
    took = say(p, b, "awake", None, t, 40)
    rows.append(row("Pia → Bo after resuming", env, took is not None, took, target=TARGET["recover"], path=peer_words(p, b)))
    if via == "direct":
        back = first_direct(p, b, t)
        rows.append(row("direct again after resuming", env, back is not None, back, target=TARGET["recover"]))
    return rows


def scenario_frozen_relay(lab):
    """Ann and Ben, both behind carrier NAT, are each friends with Carl (Mac, UPnP) and Ivy (public),
    who both run relays; Ann adds Ben. The relay carrying them freezes: messages must go round it
    (the other helper), not into it."""
    env = "cgnat ↔ cgnat, helpers Carl (upnp) and Ivy (pub)"
    d, i = lab.site("upnp").device("carl"), lab.site("pub").device("ivy")
    a, b = lab.site("cgnat").device("ann"), lab.site("cgnat").device("ben")
    lab.ready()
    d.start("--relay"); i.start("--relay", "--public", "--port", "443")
    if not (relay_offered(d) and relay_offered(i)):
        return [row("both relays offered", env, False)]
    a.start(); b.start()
    for h in (d, i):
        for x in (a, b):
            secs, err = befriend(h, x)
            if err:
                return [row(f"{x.person} meets {h.person}", env, False, note=err)]
    time.sleep(3)
    secs, err = befriend(a, b)
    if err or not a.online_seen(b, 0, 20):
        return [row("Ann adds Ben", env, False, note=err or "never online")]
    time.sleep(5)
    words = peer_words(a, b)
    h = next((h for h in (d, i) if h.id in words), None)
    if not h:
        return [row("relayed", env, None, path=words)]
    sh(["docker", "pause", h.name])
    try:
        t = a.mark("frozen")
        rows = []
        for src, dst in ((a, b), (b, a)):
            secs = say(src, dst, f"frozen{src.short}", None, t, 60)
            rows.append(row(f"{h.person}'s relay frozen: {src.person} → {dst.person}", env, secs is not None, secs, target=TARGET["recover"], path=words))
        rows.append(row("path after", env, None, path=peer_words(a, b)))
        return rows
    finally:
        sh(["docker", "unpause", h.name], check=False)


def scenario_redeem(lab, case):
    """Bo (carrier NAT) redeems Pia's link through her meeting device. `own`: Pia's phone (carrier
    NAT) and her Mac (UPnP, relay) are one person's; `asleep`: the same, her phone frozen once
    the link is out; `friend`: the Mac is her friend Carl's."""
    env = f"phone cgnat, {'her own' if case != 'friend' else 'a friend'}'s Mac upnp" + (", phone asleep" if case == "asleep" else "")
    m = lab.site("upnp").device("carl" if case == "friend" else "mac")
    p, b = lab.site("cgnat").device("pia"), lab.site("cgnat").device("bo")
    if case != "friend":
        m.person = "Pia"
    lab.ready()
    m.start("--relay", "--auto-confirm-links")
    if not relay_offered(m):
        return [row("the Mac's relay offered", env, False)]
    p.start(); b.start()
    if case == "friend":
        secs, err = befriend(m, p)
    else:
        err = link_devices(m, p)
    if err:
        return [row("Pia and the Mac", env, False, note=err)]
    time.sleep(3)
    link = p.invite()
    if case == "asleep":
        sh(["docker", "pause", p.name])
    t = b.mark("add")
    b.cmd(f"add {link}")
    hit = b.wait(r"^(added |add failed: |error: )", t, 40)
    took = (hit[0] - t) if hit else None
    ok = bool(hit) and hit[1].startswith("added ")
    rows = [row("meet by link", env, ok, took if ok else None, target=TARGET["meet"], note="" if ok else (f"{hit[1]} after {took:.1f} s" if hit else "no answer in 40 s"))]
    if case == "asleep":
        sh(["docker", "unpause", p.name])
        rows.append(row("an answer while she sleeps", env, took is not None and took <= TARGET["answer"], took, target=TARGET["answer"], note=hit[1] if hit else ""))
        if not ok:
            return rows
    if not ok:
        return rows
    for src, dst in ((b, p), (p, b)):
        secs = say(src, dst, f"hi{src.short}", None, None, 20)
        rows.append(row(f"message {src.person} → {dst.person}", env, secs is not None, secs, target=TARGET["carried"]))
    p.kill(); b.kill()
    t = b.mark("relaunch")
    p.start(); b.start()
    secs = say(b, p, "again", None, t, 40)
    rows.append(row("message after both relaunch", env, secs is not None, secs, target=TARGET["recover"]))
    return rows


def rss_mb(d):
    out = d.sh("grep VmRSS /proc/$(pgrep -x peer-node)/status", check=False).split()
    return int(out[1]) / 1024 if len(out) > 1 else 0.0


def scenario_carriers(lab):
    """Three of Carl's devices (an always-on desktop, a Mac, a phone) on one LAN, all connected,
    and Fay, a friend who is away: the phone posts to her. The others carry it once each and then
    rest; they must not pass it round (a build that did grew one carrier to 15 GB). Fay gets it
    once when she is back."""
    env = "three own devices carrying for a friend who is away"
    s = lab.site("home")
    desk, mac, phone = s.device("desk"), s.device("mac"), s.device("phone")
    fay = lab.site("pub").device("fay")
    for x in (desk, mac, phone):
        x.person = "Carl"
    lab.ready()
    desk.start("--auto-confirm-links"); mac.start(); phone.start(); fay.start()
    for x in (mac, phone):
        err = link_devices(desk, x)
        if err:
            return [row("Carl's devices linked", env, False, note=err)]
    secs, err = befriend(fay, desk)
    if err or not phone.wait(r"^· online Fay's ", 0, 30):
        return [row("Fay is Carl's friend on every device", env, False, note=err or "the phone never saw her")]
    fay.kill()
    if not phone.wait(r"^· offline Fay's ", 0, 45):
        return [row("Fay away", env, False, note="never offline")]
    t = phone.mark("post")
    phone.cmd("post Fay away")
    time.sleep(5)
    before = {x.short: rss_mb(x) for x in (desk, mac)}
    time.sleep(60)
    grew = max(rss_mb(x) - before[x.short] for x in (desk, mac))
    held = sum(len(x.traces("held", t)) for x in (desk, mac, phone))
    rows = [row("carriers rest", env, held <= 6 and grew < 50, note=f"{held} envelope holds in 65 s, carriers' memory +{grew:.0f} MB")]
    t = fay.mark("back")
    fay.start()
    time.sleep(15)
    got = len(fay.find(r'^· inbox \w+: "away"', t))
    rows.append(row("Fay gets it once, back", env, got == 1, note=f"{got} copies"))
    return rows


def call_state(x):
    """(ended, datagrams heard) for `x`'s current call."""
    t = x.mark("callstat")
    x.cmd("callstat")
    hit = x.wait(r"^(call with |no call)", t, 5)
    if not hit or hit[1].startswith("no call"):
        return True, 0
    m = re.search(r"heard (\d+) datagrams, (\w+)", hit[1])
    return (m.group(2) == "ended", int(m.group(1))) if m else (True, 0)


def ring(caller, callee, name):
    """`caller` calls `callee`'s device (its contact `name`): (seconds to up, how, None) or
    (None, None, why)."""
    t = caller.mark("call")
    caller.cmd(f"call {name} {callee.id}")
    hit = caller.wait(r"^(· call up with |call failed: )", t, 25)
    if not hit:
        return None, None, "no answer in 25 s"
    if hit[1].startswith("call failed: "):
        return None, None, f"{hit[1][len('call failed: '):]} after {hit[0] - t:.1f} s"
    if not callee.wait(r"^· media from ", t, 5) or not caller.wait(r"^· media from ", t, 5):
        return None, None, "up, but no media both ways"
    return hit[0] - t, hit[1].split(" via ", 1)[1].rsplit(" in ", 1)[0], None


def scenario_call(lab, case):
    """A call (`peer-node call`: a Live connection, a datagram every 20 ms each way) from Bo to
    Pia's phone, `direct` (Bo's router maps a port), through Pia's `own` Mac, or through `friend`
    Carl's (Live is refused through a third person's relay: it must fail at once, saying why).
    Then mid-call the phone changes network, freezes 15 s, hangs up with no network, and is
    killed: each time the call carries on or ends on both sides within seconds, never on one."""
    env = f"phone v6home ⇄ mobile, {case}"
    wifi, cell = lab.site("v6home"), lab.site("mobile")
    p = wifi.device("pia")
    b = lab.site("upnp" if case == "direct" else "cgnat").device("bo")
    h = lab.site("upnp").device("mac" if case == "own" else "carl") if case != "direct" else None
    if case == "own":
        h.person = "Pia"
    lab.ready()
    if h:
        h.start("--relay", "--auto-confirm-links")
        if not relay_offered(h):
            return [row("the relay offered", env, False)]
    p.start(); b.start()
    if case == "own":
        err = link_devices(h, p)
        if err:
            return [row("Pia's phone and Mac", env, False, note=err)]
    elif case == "friend":
        for x in (p, b):
            secs, err = befriend(h, x)
            if err or not x.wait(r"^· online Carl's ", 0, 15):
                return [row(f"{x.person} meets Carl", env, False, note=err or "never online")]
    time.sleep(2)
    secs, err = befriend(b, p) if case != "own" else befriend(p, b)
    if err or not b.wait(rf"^· online Pia's ", 0, 20):
        return [row("Pia and Bo", env, False, note=err or "never online")]
    time.sleep(3)
    up, how, why = ring(b, p, "Pia")
    if case == "friend":
        return [row("a call through a friend's relay fails at once, saying why", env, up is None and why and "policy" in why.lower() and float(why.rsplit(" after ", 1)[1][:-2]) <= TARGET["online-relayed"], note=why or f"up via {how}")]
    rows = [row("call connects, media both ways", env, up is not None, up, path=how or "", target=3, note=why or "")]
    if up is None:
        return rows

    def outcome(label, since, timeout=15):
        """Ended on both sides, carried on, or one side left in the call."""
        end = time.time() + timeout
        while time.time() < end:
            ends = [x.find(r"^· call ended: ", since) for x in (p, b)]
            if all(ends):
                took = max(e[0][0] for e in ends) - since
                rows.append(row(f"{label}: ended on both sides", env, took <= 6, took, target=6, note=" · ".join(f"{x.person}: {e[0][1][len('· call ended: '):]}" for x, e in zip((p, b), ends))))
                return True
            time.sleep(0.5)
        ends = [bool(x.find(r"^· call ended: ", since)) for x in (p, b)]
        if any(ends):
            rows.append(row(f"{label}: one side left in the call", env, False, note=f"ended on {', '.join(x.person for x, e in zip((p, b), ends) if e)} only, {timeout} s on"))
            return True
        heard = [call_state(x)[1] for x in (p, b)]
        time.sleep(2)
        again = [call_state(x)[1] for x in (p, b)]
        carried = all(a > h0 for a, h0 in zip(again, heard))
        rows.append(row(f"{label}: carried on", env, carried, note="media both ways" if carried else f"neither ended, media {heard} → {again}"))
        return False

    def again():
        up, how, why = ring(b, p, "Pia")
        if up is None:
            rows.append(row("call again", env, False, note=why))
        return up is not None

    t = p.mark("leave")
    p.leave()
    time.sleep(2)
    cell.arrive(p)
    ended = outcome("phone changes network mid-call", t)
    if ended and not again():
        return rows
    t = b.mark("freeze")
    sh(["docker", "pause", p.name])
    hit = b.wait(r"^· call ended: ", t, 15)
    rows.append(row("phone frozen: Bo's side ends", env, hit is not None and hit[0] - t <= 6, (hit[0] - t) if hit else None, target=6, note=hit[1] if hit else "Bo still in the call 15 s on"))
    t = b.mark("thaw")
    sh(["docker", "unpause", p.name])
    hit = p.wait(r"^· call ended: ", t, 15)
    rows.append(row("phone thaws: its side ends", env, hit is not None and hit[0] - t <= 3, (hit[0] - t) if hit else None, target=3, note=hit[1] if hit else "the phone still in the call"))
    time.sleep(2)
    if not again():
        return rows
    t = p.mark("hangup")
    p.leave()
    p.cmd("hangup")
    hit = b.wait(r"^· call ended: ", t, 15)
    rows.append(row("phone hangs up with no network: Bo's side ends", env, hit is not None and hit[0] - t <= 6, (hit[0] - t) if hit else None, target=6, note=hit[1] if hit else "Bo still in the call 15 s on"))
    wifi.arrive(p)
    time.sleep(3)
    if not again():
        return rows
    t = b.mark("kill")
    p.kill()
    hit = b.wait(r"^· call ended: ", t, 15)
    rows.append(row("phone's app killed: Bo's side ends", env, hit is not None and hit[0] - t <= 6, (hit[0] - t) if hit else None, target=6, note=hit[1] if hit else "Bo still in the call 15 s on"))
    return rows


def scenario_burst(lab, sender_leaves):
    """Bo is away; Ana posts 200 envelopes to him at once, as an app posting many frames does,
    with Carl (public, a contact of both) connected to carry. Bo comes back: every one arrives,
    once. `sender_leaves`: Ana is gone by then, so only what Carl holds can reach him."""
    env = "200 envelopes at once to an away friend" + (", sender gone when he is back" if sender_leaves else "")
    d = lab.site("pub").device("carl")
    a, b = lab.site("home").device("ana"), lab.site("home").device("bo")
    lab.ready()
    d.start("--relay", "--public", "--port", "443")
    a.start(); b.start()
    for x in (a, b):
        secs, err = befriend(d, x)
        if err or not x.wait(r"^· online Carl's ", 0, 15):
            return [row(f"{x.person} meets Carl", env, False, note=err or "never online")]
    secs, err = befriend(a, b)
    if err or not a.online_seen(b, 0, 20):
        return [row("Ana and Bo", env, False, note=err or "never online")]
    b.kill()
    if not a.wait(r"^· offline Bo's ", 0, 45):
        return [row("Bo away", env, False, note="never offline")]
    t = a.mark("burst")
    a.cmd("burst Bo 200")
    hit = a.wait(r"^burst posted ", t, 60)
    posted = hit[1] if hit else "no answer"
    time.sleep(3)
    held = len({tr.get("id") for _, tr in d.traces("held", t) if tr.get("new")})
    if sender_leaves:
        a.kill()
    t = b.mark("back")
    b.start()
    end = time.time() + 40
    got = 0
    while time.time() < end:
        got = len({l.split('"')[1] for _, l in b.find(r'^· inbox \w+: "burst\d+"', t)})
        if got == 200:
            break
        time.sleep(1)
    copies = len(b.find(r'^· inbox \w+: "burst\d+"', t))
    return [row("Bo back: every one arrives, once", env, got == 200 and copies == 200, (time.time() - t) if got == 200 else None, note=f"{got} of 200, {copies} copies; Carl held {held}; {posted}")]


# ── The path census: which path each pair of devices ends up on, from the wire. ──

# Pairs of environments (inviter, redeemer): every realistic way two people's devices sit.
CENSUS = [
    ("pub", "upnp"), ("upnp", "upnp"), ("home", "home"), ("upnp", "home"),
    ("upnp", "cell-xlat"), ("upnp", "cell60"), ("upnp", "cafe"), ("upnp", "hotel"), ("home", "cell-xlat"),
    ("cell-xlat", "cell-xlat"), ("cell-xlat", "cell60"), ("cell60", "cell60"), ("v6home", "cell-xlat"), ("v6home", "v6home"),
    ("v6home", "cell60"), ("cafe", "cafe"), ("cafe", "cell-xlat"), ("cafe", "cell60"), ("hotel", "cell-xlat"),
    ("double", "upnp"), ("cgnat", "home"), ("v6open", "cell-xlat"), ("home60", "home120"), ("cell30", "upnp"),
    ("cell60", "home"),
]
NOISE = "not port 5353 and not port 1900 and not port 5351 and not port 5000 and not port 53"


def capture(devices, secs=None):
    """tcpdump on every device at once, until the returned function is called; it then gives each
    one's flows with its own addresses left out: {device: {(family, proto, remote ip, remote port):
    [packets out, packets in]}}. Not a fixed window: starting fifty and posting a message per pair
    takes seconds, and a window that closed first saw nothing on a pair whose keepalives are 20 s
    apart."""
    for d in devices:
        d.sh(f"(tcpdump -nn -l -i any '(udp or tcp) and {NOISE}' > /tmp/flows 2>/dev/null &); true")

    def done():
        for d in devices:
            d.sh("pkill -x tcpdump; true", check=False)
        time.sleep(0.3)
        return {d: flows_of(d) for d in devices}
    return done


def flows_of(d):
    mine = set(d.addrs())
    out = {}
    for line in d.sh("cat /tmp/flows", check=False).splitlines():
        m = re.search(r" (IP6?) (\S+)\.(\d+) > (\S+)\.(\d+): ", line)
        if not m:
            continue
        fam, src, sport, dst, dport = m.groups()
        sent = src in mine
        remote, port = (dst, dport) if sent else (src, sport)
        key = ("v6" if fam == "IP6" else "v4", "tcp" if "Flags" in line else "udp", remote, int(port))
        out.setdefault(key, [0, 0])[0 if sent else 1] += 1
    return out


def mapped_ports(d):
    """The external UDP ports `d`'s router holds for it."""
    return {int(tr["external"].rsplit(":", 1)[1]) for _, tr in d.traces("portmap") if tr.get("proto") == "udp"}


def where(d):
    """Every address the far side may see `d` at."""
    return {x for x in (d.ip4, d.ip6, d.site.public_ip) if x}


def classify(a, b, fa, fb, helpers=()):
    """The path between a and b, from both ends' flows: v6, v4 (to a public address), mapped (a
    router's port mapping carries it), punched (both behind NAT, no mapping), lan, vpn, helper
    (TCP through a relay), or none."""
    # A path carries both ways: packets only out are a punch that did not get through.
    def best(f, other):
        udp = {k: sum(n) for k, n in f.items() if k[1] == "udp" and k[2] in where(other) and min(n) > 0}
        return max(udp, key=udp.get) if udp else None
    ab, ba = best(fa, b), best(fb, a)
    if not ab and not ba:
        relayed = any(k[1] == "tcp" and k[2] in {h.ip4 for h in helpers} | {h.site.public_ip for h in helpers if h.site.public_ip} for k in fa)
        return "helper" if relayed else "none"
    fam, _, ip, port = ab or ba
    if fam == "v6":
        return "v6"
    if ip == b.ip4 and a.ip4.rsplit(".", 1)[0] == b.ip4.rsplit(".", 1)[0]:
        return "lan"
    if ip.startswith("100.100."):
        return "vpn"
    if b.site.public_ip is None or a.site.public_ip is None:
        return "v4"
    if (ab and ab[3] in mapped_ports(b)) or (ba and ba[3] in mapped_ports(a)):
        return "mapped"
    return "punched"


def first_direct(a, b, since):
    hit = a.find(rf"^· (online|path) (?:\S+'s |my )?{b.id}\b.*\bdirect\b", since)
    return (hit[0][0] - since) if hit else None


def scenario_census(lab, mode):
    """Every pair in CENSUS at once: the redeemer adds the inviter by link, alone (`link`), or with
    Rex (public, running a relay) a friend of both, so the link names his relay (`helper`). The path
    each pair is on 15 s after meeting, how soon it went direct, then after 10 minutes idle: still
    the same path, what a message costs then, and the packets the pair sent each other meanwhile."""
    rex = lab.site("pub").device("rex") if mode == "helper" else None
    pairs = [(ea, eb, lab.site(ea).device(f"a{i}"), lab.site(eb).device(f"b{i}")) for i, (ea, eb) in enumerate(CENSUS)]
    lab.ready()
    helpers = [rex] if rex else []
    if rex:
        rex.start("--relay", "--public", "--port", "443")
    for _, _, a, b in pairs:
        a.start(); b.start()
    if rex:
        for _, _, a, b in pairs:
            for x in (a, b):
                befriend(rex, x)
        time.sleep(5)
    met, how = {}, {}
    for ea, eb, a, b in pairs:
        t = b.mark("meet")
        if mode == "reply":
            secs, how[(a, b)], err = befriend_reply(a, b)
        else:
            secs, err = befriend(a, b)
        met[(a, b)] = (t, secs, err)
    time.sleep(15)

    def measure(tag):
        devices = [x for _, _, a, b in pairs for x in (a, b)]
        done = capture(devices, 6)
        time.sleep(0.5)
        marks = {}
        for _, _, a, b in pairs:
            marks[(a, b)] = a.mark(f"{tag}-say")
            a.cmd(f"post {b.person} {tag}{a.short}")
        time.sleep(7)
        flows = done()
        out = {}
        for _, _, a, b in pairs:
            hit = b.find(rf'^· inbox \w+: "{tag}{a.short}"', marks[(a, b)])
            cls = classify(a, b, flows[a], flows[b], helpers)
            if cls == "none" and hit:
                # Delivered, yet no flow both ways to where the lab thinks b is: say where it went.
                top = sorted(flows[a].items(), key=lambda kv: -sum(kv[1]))[:3]
                print(f"    census: {a.short}→{b.short} delivered on no flow the lab knows; a's flows {top}; b at {sorted(where(b))}", flush=True)
            out[(a, b)] = (cls, (hit[0][0] - marks[(a, b)]) if hit else None)
        return out

    first = measure("first")
    for _, _, a, b in pairs:
        a.sh(f"(timeout 600 tcpdump -nn -l -i any 'udp and {NOISE}' > /tmp/idle 2>/dev/null &); true")
    time.sleep(600)
    idle_pkts = {}
    for _, _, a, b in pairs:
        n = 0
        for line in a.sh("cat /tmp/idle", check=False).splitlines():
            if any(f" {ip}." in line for ip in where(b)):
                n += 1
        idle_pkts[(a, b)] = n * 6
    after = measure("idle")
    rows = []
    for ea, eb, a, b in pairs:
        t, secs, err = met[(a, b)]
        env = f"{ea} ← {eb}" + (" + a friend's relay" if rex else "") + (" by reply" if mode == "reply" else "")
        if err:
            rows.append(row("census · first contact", env, False, path="none", note=f"meet: {err}"))
            rows.append(row("census · after 10 min idle", env, False, path="none"))
            continue
        cls, msg = first[(a, b)]
        rows.append(row("census · first contact", env, cls != "none" and msg is not None, first_direct(a, b, t), path=cls, note=f"met {'by ' + how[(a, b)] + ' ' if (a, b) in how else ''}in {secs:.1f} s; first direct {fmt(first_direct(a, b, t)) or 'never'}; message {fmt(msg) or 'lost'}"))
        cls2, msg2 = after[(a, b)]
        rows.append(row("census · after 10 min idle", env, cls2 != "none" and msg2 is not None and cls2 == cls, msg2, path=cls2, target=TARGET["message"], note=f"{idle_pkts[(a, b)]} packets/hour to its friend" + ("" if cls2 == cls else f"; was {cls}")))
    return rows


def scenario_freeze(lab, secs):
    """Ana (home) and Bo (UPnP) are direct, both friends of Rex (public, a relay), who carries.
    Bo's device freezes; `secs` later Ana writes him. How soon a carrier holds it (the held
    connection is not idle yet: the ask on it has to go unanswered first), and how soon Bo has it
    once he thaws."""
    env = f"home → upnp, Bo frozen {secs} s, Rex (pub) carries"
    r, a, b = lab.site("pub").device("rex"), lab.site("home").device("ana"), lab.site("upnp").device("bo")
    lab.ready()
    r.start("--relay", "--public", "--port", "443")
    a.start(); b.start()
    for x in (a, b):
        _, err = befriend(r, x)
        if err:
            return [row(f"{x.person} meets Rex", env, False, note=err)]
    _, err = befriend(b, a)
    if err or not a.online_seen(b, 0, 15):
        return [row("Ana adds Bo", env, False, note=err or "never online")]
    time.sleep(5)
    sh(["docker", "pause", b.name])
    try:
        time.sleep(secs)
        t = a.mark("frozen-say")
        tell(a, b, f"frozen{secs}")
        held = r.wait(rf'"ev":"held".*"for":"{b.id}"', t, 90)
        stalled = a.wait(rf'"ev":"stalled".*"device":"{b.id}"', t, 1)
        # Marked on Ana's box (one daemon clock): Bo prints the message the moment he runs again.
        t2 = a.mark("thaw")
    finally:
        sh(["docker", "unpause", b.name], check=False)
    got = b.wait(rf'^· inbox \w+: "frozen{secs}"', t2, 30)
    note = f"Ana gave up on the held connection after {fmt(stalled[0] - t)}" if stalled else "no stall"
    return [row("a carrier holds it", env, held is not None, (held[0] - t) if held else None, target=TARGET["carried"], note=note),
            row("Bo has it after he thaws", env, got is not None, (got[0] - t2) if got else None, target=TARGET["recover"])]


def scenario_hold(lab, env, secs):
    """Ana (`env`) has an app connection to Bo (public) open, as a call or a chat keeps one, and
    sends nothing for `secs`. Her next message must go on that same connection: a send on a cached
    connection that died fails, and the message goes to carriers instead."""
    label = f"{env} → pub, app connection idle {secs // 60} min"
    a, b = lab.site(env).device("ana"), lab.site("pub").device("bo")
    lab.ready()
    b.start(); a.start()
    _, err = befriend(b, a)
    if err or not a.online_seen(b, 0, 20):
        return [row("Ana adds Bo", label, False, note=err or "never online")]
    t = a.mark("first")
    a.cmd(f"send {b.person} first")
    if not a.wait(r"^sent first .* direct ", t, 10):
        return [row("first message direct", label, False)]
    t = a.mark("idle")
    time.sleep(secs)
    dropped = a.find(rf"^· offline (?:\S+'s )?{b.id}", t)
    t2 = a.mark("again")
    a.cmd(f"send {b.person} again")
    hit = a.wait(r"^sent again .* (direct|to carriers) in (\d+) ms", t2, 20)
    got = b.wait(r'^· inbox app: "again"', t2, 20)
    ok = hit is not None and " direct " in hit[1] and got is not None and not dropped
    return [row("held while idle, then a message on it", label, ok, (got[0] - t2) if got else None, target=TARGET["message"],
                note=(hit[1].split(" ", 1)[1] if hit else "no answer") + ("; Bo seen offline meanwhile" if dropped else "; never offline"))]


def scenario_upgrade(lab, move):
    """Ana and Bo (two homes) meet through Rex's relay (public) while UDP between their routers is
    blocked, and stay relayed 8 minutes; then the block is lifted. How soon they are direct: on
    iroh's own upgrade rounds alone, or (`move`) with Ana's network changing 2 s after the lift
    (an address added, as a phone joining Wi-Fi gets one)."""
    env = "home ⇄ home + Rex's relay, UDP blocked 8 min, then lifted" + (", then Ana's network changes" if move else "")
    r = lab.site("pub").device("rex")
    sa, sb = lab.site("home"), lab.site("home")
    a, b = sa.device("ana"), sb.device("bo")
    lab.ready()
    block = f"iptables -I FORWARD 1 -p udp -d {sb.public_ip} -j DROP; iptables -I FORWARD 1 -p udp -s {sb.public_ip} -j DROP"
    sa.router.sh(block)
    r.start("--relay", "--public", "--port", "443")
    iroh = "iroh::_events=debug,iroh::socket::remote_map=debug"
    a.start(log=iroh); b.start(log=iroh)
    for x in (a, b):
        _, err = befriend(r, x)
        if err:
            return [row(f"{x.person} meets Rex", env, False, note=err)]
    time.sleep(3)
    _, err = befriend(b, a)
    if err or not a.online_seen(b, 0, 20):
        return [row("Ana adds Bo", env, False, note=err or "never online")]
    time.sleep(480)
    try:
        return upgrade_rows(lab, env, sa, a, b, block, move)
    finally:
        # iroh's own account of its rounds, for when the row says something odd.
        for x in (a, b):
            lines = [l for _, l in x.logs() if "qnt" in l or "holepunch" in l or "path::" in l or "NAT traversal" in l]
            (LAB / "results" / f"upgrade{'-move' if move else ''}-{lab.tag}-{x.short}.log").write_text("\n".join(lines) + "\n")


def upgrade_rows(lab, env, sa, a, b, block, move):
    words = peer_words(a, b)
    if "direct" in words:
        return [row("relayed while blocked", env, False, path=words)]
    sa.router.sh(block.replace("-I FORWARD 1", "-D FORWARD"))
    t = a.mark("lifted")
    if move:
        time.sleep(2)
        a.sh(f"ip addr add 10.{sa.k}.0.77/24 dev eth0")
    # The event, or (a path that moved without one) `peers` saying so, polled every 10 s.
    secs, how, end = None, "", time.time() + 420
    while time.time() < end and secs is None:
        hit = a.find(rf"^· (online|path) (?:\S+'s )?{b.id}\b.*\bdirect\b", t)
        if hit:
            secs, how = hit[0][0] - t, "path event"
        elif "direct" in peer_words(a, b):
            secs, how = time.time() - t, "peers, within 10 s"
        else:
            time.sleep(10)
    return [row("direct after the block lifts", env, secs is not None, secs, target=10 if move else 300,
                path=peer_words(a, b), note=f"relayed before: {words}" + (f"; seen by {how}" if how else ""))]


def scenario_failover(lab, kind, traffic):
    """The selected path dies under a working pair and nothing on the device notices (the Wi-Fi
    still up, its upstream gone). `v6`: Ana (v6home) and Bo (pub) on IPv6; Ana's router drops all
    IPv6, IPv4 stays. `relay`: Ana and Bo (two homes) punched direct, Rex (pub) a friend of both
    running a relay; Ana's router drops UDP to and from Bo, the relay (TCP) stays. With `traffic`
    Ana writes Bo 2 s after; without, nothing is sent and the path is watched for 90 s."""
    env = {"v6": "v6home ⇄ pub, IPv6 dropped", "relay": "home ⇄ home + Rex's relay, UDP between them dropped"}[kind]
    env += "" if traffic else ", idle"
    r = lab.site("pub").device("rex") if kind == "relay" else None
    sa = lab.site("v6home" if kind == "v6" else "home")
    sb = lab.site("pub" if kind == "v6" else "home")
    a, b = sa.device("ana"), sb.device("bo")
    lab.ready()
    helpers = [r] if r else []
    if r:
        r.start("--relay", "--public", "--port", "443")
    a.start(); b.start()
    for x in (a, b) if r else ():
        _, err = befriend(r, x)
        if err:
            return [row(f"{x.person} meets Rex", env, False, note=err)]
    if r:
        time.sleep(3)
    _, err = befriend(b, a)
    if err or not a.online_seen(b, 0, 20):
        return [row("Ana adds Bo", env, False, note=err or "never online")]
    time.sleep(40)

    def path(tag):
        done = capture([a, b], 6)
        time.sleep(0.5)
        t = a.mark(f"{tag}-say")
        a.cmd(f"post {b.person} {tag}")
        time.sleep(7)
        flows = done()
        hit = b.find(rf'^· inbox \w+: "{tag}"', t)
        return classify(a, b, flows[a], flows[b], helpers), (hit[0][0] - t) if hit else None

    before, _ = path("before")
    # The IPv6 case needs the pair on IPv6 first: a pair still on IPv4 would not feel the drop.
    for n in range(4 if kind == "v6" else 0):
        if before == "v6":
            break
        time.sleep(15)
        before, _ = path(f"before{n}")
    if kind == "v6" and before != "v6":
        return [row("on IPv6 before the drop", env, None, path=before, note="never on IPv6 within 100 s: nothing to drop")]
    if kind == "v6":
        sa.router.sh("ip6tables -I FORWARD 1 -j DROP")
    else:
        ip = sb.public_ip
        sa.router.sh(f"iptables -I FORWARD 1 -p udp -d {ip} -j DROP; iptables -I FORWARD 1 -p udp -s {ip} -j DROP")
    t = a.mark("dropped")
    rows = []
    if traffic:
        time.sleep(2)
        secs = say(a, b, "afterdrop", None, None, 60)
        rows.append(row("message after the path died", env, secs is not None, secs, target=TARGET["recover"], note=f"was {before}"))
    else:
        moved = a.wait(rf"^· (path|offline) (?:\S+'s )?{b.id}\b", t, 90)
        rows.append(row("path moved without traffic", env, moved is not None, (moved[0] - t) if moved else None, target=TARGET["recover"],
                        note=f"was {before}; " + (moved[1].split(b.id, 1)[1].strip() if moved else "no path event in 90 s")))
    after, msg = path("after")
    rows.append(row("path after", env, after not in ("none", before) and msg is not None, msg, path=after, note=f"was {before}"))
    return rows


# ── How long each network keeps an idle UDP pinhole: raw sockets, no peer. ──

PIN_ECHO = r"""
import socket, sys, threading, time
def serve(af, host):
    s = socket.socket(af, socket.SOCK_DGRAM)
    if af == socket.AF_INET6:
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    s.bind((host, 9999))
    timers = {}
    while True:
        data, addr = s.recvfrom(100)
        tag, wait = data.decode().split()[1], int(data.decode().split()[2])
        s.sendto(b"ack", addr)
        key = (addr, tag)
        if key in timers: timers[key].cancel()
        timers[key] = threading.Timer(wait, lambda a=addr, t=tag: s.sendto(f"probe {t}".encode(), a)); timers[key].start()
threading.Thread(target=serve, args=(socket.AF_INET6, "::"), daemon=True).start()
serve(socket.AF_INET, "0.0.0.0")
"""

PIN_PROBE = r"""
import socket, sys, threading, time
echo, fam, waits = sys.argv[1], sys.argv[2], [int(x) for x in sys.argv[3].split(",")]
af = socket.AF_INET6 if fam == "6" else socket.AF_INET
def listen(s, w):
    s.settimeout(max(waits) + 20)
    try:
        s.recvfrom(100); print(f"{fam} {w} kept", flush=True)
    except Exception:
        print(f"{fam} {w} gone", flush=True)
socks = []
for w in waits:
    s = socket.socket(af, socket.SOCK_DGRAM); s.bind(("::" if fam == "6" else "0.0.0.0", 0)); s.settimeout(3)
    socks.append((s, w))
# Traffic both ways over 3 s, as a live connection's: Linux holds such a flow for its longer
# "stream" lifetime, a flow seen for a moment only for the short one.
for round in range(2):
    for s, w in socks:
        s.sendto(f"hello {w} {w}".encode(), (echo, 9999))
        try: s.recvfrom(100)
        except Exception: pass
    if round == 0:
        time.sleep(3)
for s, w in socks:
    threading.Thread(target=listen, args=(s, w)).start()
"""

PIN_WAITS = [10, 20, 25, 35, 50, 65, 90, 125, 185, 250]


def scenario_pinholes(lab):
    """For each network, how long an established UDP flow may sit idle before its router forgets
    it: one socket per wait, two packets out and back, then silence until the echo box speaks."""
    envs = ["home", "upnp", "short", "home60", "home120", "cell-xlat", "cell60", "cell30", "mobile", "v6home", "cafe", "double"]
    echo = lab.site("pub").device("echo")
    probes = [(e, lab.site(e).device(f"p{i}")) for i, e in enumerate(envs)]
    lab.ready()
    echo.sh(f"cat > /tmp/echo.py <<'X'\n{PIN_ECHO}\nX\n(python3 /tmp/echo.py > /tmp/echo.log 2>&1 &); true")
    time.sleep(1)
    for e, d in probes:
        script = f"cat > /tmp/probe.py <<'X'\n{PIN_PROBE}\nX\n"
        runs = [f"(python3 /tmp/probe.py {echo.ip4} 4 {','.join(map(str, PIN_WAITS))} > /tmp/pin4 2>&1 &)"]
        if d.ip6:
            runs.append(f"(python3 /tmp/probe.py {echo.ip6} 6 {','.join(map(str, PIN_WAITS))} > /tmp/pin6 2>&1 &)")
        d.sh(script + "; ".join(runs) + "; true")
    time.sleep(max(PIN_WAITS) + 30)
    rows = []
    for e, d in probes:
        for fam in ("4", "6") if d.ip6 else ("4",):
            got = {int(w): v for w, v in (l.split()[1:3] for l in d.sh(f"cat /tmp/pin{fam}", check=False).split("\n") if l.strip()) if True}
            kept = [w for w in PIN_WAITS if got.get(w) == "kept"]
            gone = [w for w in PIN_WAITS if got.get(w) == "gone"]
            lasts = max(kept) if kept else 0
            rows.append(row(f"idle UDP pinhole, IPv{fam}", e, None, None, note=f"kept {lasts} s" + (f", gone by {min(w for w in gone if w > lasts)} s" if any(w > lasts for w in gone) else f", still open at {max(PIN_WAITS)} s")))
    return rows


def scenario_reach(lab):
    """Pia's phone on Wi-Fi with three people near her: Bo (his router maps a port), Cy (carrier
    NAT, reached through Carl's relay, a friend of both) and her own Mac. The phone moves to
    cellular, every address new: how soon each holds its new record, is direct to it again (Cy
    stays relayed), and has a message from it."""
    env = "phone v6home ⇄ mobile; Bo upnp, Cy cgnat via Carl, her Mac upnp"
    wifi, cell = lab.site("v6home"), lab.site("mobile")
    p = wifi.device("pia")
    b, c = lab.site("upnp").device("bo"), lab.site("cgnat").device("cy")
    d, m = lab.site("upnp").device("carl"), lab.site("upnp").device("mac")
    m.person = "Pia"
    lab.ready()
    for x in (d, m):
        x.start("--relay", "--auto-confirm-links")
        if not relay_offered(x):
            return [row(f"{x.short}'s relay offered", env, False)]
    p.start(); b.start(); c.start()
    err = link_devices(m, p)
    for x in (p, c):
        err = err or befriend(d, x)[1]
    err = err or befriend(b, p)[1] or befriend(c, p)[1]
    if err:
        return [row("setup", env, False, note=err)]
    time.sleep(8)
    p.leave()
    time.sleep(2)
    t = p.mark("arrive")
    cell.arrive(p)
    rows = []
    for x, who in ((b, "Bo"), (c, "Cy"), (m, "her Mac")):
        hit = x.wait(rf"^· record (?:Pia's|my) {p.id}\b", t, 30)
        rows.append(row(f"{who} holds the phone's new record", env, hit is not None, (hit[0] - t) if hit else None, target=TARGET["online"]))
        if x is not c:
            back = first_direct(x, p, t)
            rows.append(row(f"{who} is direct to the phone again", env, back is not None, back, target=TARGET["recover"]))
    for x, who in ((b, "Bo"), (c, "Cy")):
        took = say(p, x, f"moved{x.short}", None, t, 30)
        rows.append(row(f"the phone → {who}", env, took is not None, took, target=TARGET["recover"]))
    return rows


SCENARIOS = {
    # Two strangers meeting by link, no helpers: one side must be reachable.
    **{f"pair:{a}-{b}": (scenario_pair, a, b) for a, b in [
        ("pub", "home"), ("upnp", "home"), ("pmp", "cgnat"), ("liar", "home"), ("home", "home"), ("cgnat", "cgnat"),
        ("v6home", "mobile"), ("v6open", "mobile"), ("pub", "double"), ("double", "pub"), ("udpblock", "pub"), ("pub", "lossy"), ("pub", "udpblock")]},
    "pair:pmp-cgnat-late": (scenario_pair, "pmp", "cgnat", False, 6),
    # The same with a relay friend on a public address (port 443) in the circle.
    **{f"relay:{a}-{b}": (scenario_pair, a, b, True) for a, b in [
        ("home", "home"), ("bare", "bare"), ("cgnat", "home"), ("cgnat", "cgnat"), ("double", "mobile"), ("udpblock", "home"), ("mobile", "mobile"), ("v6home", "v6home"), ("lossy", "cgnat")]},
    # Introductions: two mutuals behind NATs, a friend who reaches both.
    **{f"intro:{a}-{b}": (scenario_introduce, a, b) for a, b in [
        ("home", "home"), ("bare", "bare"), ("home", "cgnat"), ("cgnat", "cgnat"), ("v6home", "v6home"), ("mobile", "v6home"), ("double", "home"), ("short", "home")]},
    "intro-relay:cgnat-cgnat": (scenario_introduce, "cgnat", "cgnat", True),
    # A relay friend at home behind a mapping router: its LAN URLs answer nobody away from it.
    **{f"relay-home:{a}-{b}": (scenario_pair, a, b, "upnp") for a, b in [("cgnat", "cgnat"), ("cgnat", "home")]},
    # The same friend behind a router that grants mappings and forwards nothing.
    "relay-liar:upnp-home": (scenario_pair, "upnp", "home", "liar"),
    # Both on one tailnet besides: the VPN is the way (a laptop on a hotspot and an always-on machine at home).
    "vpn:cgnat-home": (scenario_pair, "cgnat", "home", False, 0, True),
    "vpn-relay-home:cgnat-home": (scenario_pair, "cgnat", "home", "upnp", 0, True),
    # One event at a time, each on a fresh working pair.
    **{f"dyn:{e}:{a}-{b}": (scenario_dynamics, a, b, e) for e, a, b in [
        ("wake", "home", "upnp"), ("wake", "mobile", "pub"), ("move", "home", "upnp"), ("move", "v6home", "pub"),
        ("reboot", "cgnat", "upnp"), ("reboot", "home", "pub"), ("dead", "home", "upnp"), ("idle", "short", "upnp"), ("idle", "mobile", "pub")]},
    "meetmove:upnp-cgnat": (scenario_meeting_moves, "upnp", "cgnat"),
    # The demo: a group chat Carl's Mac proxies, and phones that move, sleep and redeem links.
    **{f"circle:{k}:{a}-{b}": (scenario_circle, a, b, k) for k, a, b in [
        ("chat", "mobile", "home"), ("chat", "cgnat", "cgnat"), ("space", "mobile", "home"), ("space", "cgnat", "cgnat"), ("contacts", "cgnat", "cgnat")]},
    **{f"phone:{v}": (scenario_phone, v) for v in ("direct", "relay")},
    **{f"suspend:{v}": (scenario_suspend, v) for v in ("direct", "relay")},
    **{f"suspend-move:{v}": (scenario_suspend, v, True) for v in ("direct", "relay")},
    "frozen-relay:cgnat-cgnat": (scenario_frozen_relay,),
    # Since keepalives went to the selected path alone: a frozen peer, and a selected path dying.
    **{f"freeze:{n}": (scenario_freeze, n) for n in (10, 40)},
    "hold:cell30": (scenario_hold, "cell30", 300),
    **{f"upgrade:late{'-move' if m else ''}": (scenario_upgrade, m) for m in (False, True)},
    **{f"failover:{k}{'' if t else '-idle'}": (scenario_failover, k, t) for k in ("v6", "relay") for t in (True, False)},
    **{f"redeem:{c}": (scenario_redeem, c) for c in ("own", "asleep", "friend")},
    "carriers:three": (scenario_carriers,),
    **{f"call:{c}": (scenario_call, c) for c in ("direct", "own", "friend")},
    **{f"census:{m}": (scenario_census, m) for m in ("link", "helper", "reply")},
    "pinholes": (scenario_pinholes,),
    "reach:move": (scenario_reach,),
    **{f"suspend10:{v}": (scenario_suspend, v, False, 600) for v in ("direct", "relay")},
    "suspend10-move:relay": (scenario_suspend, "relay", True, 600),
    # The same, each message to a contact sent as baud sends it.
    "send:circle:contacts:cgnat-cgnat": (sends, scenario_circle, "cgnat", "cgnat", "contacts"),
    **{f"send:phone:{v}": (sends, scenario_phone, v) for v in ("direct", "relay")},
    **{f"send:suspend:{v}": (sends, scenario_suspend, v) for v in ("direct", "relay")},
    "send:suspend-move:relay": (sends, scenario_suspend, "relay", True),
    "send:frozen-relay:cgnat-cgnat": (sends, scenario_frozen_relay),
    "send:redeem:own": (sends, scenario_redeem, "own"),
    "burst:sender-stays": (scenario_burst, False),
    "burst:sender-leaves": (scenario_burst, True),
}


def fmt(x):
    return "" if x is None else (f"{x * 1000:.0f} ms" if x < 1 else f"{x:.1f} s")


def census_summary(rows):
    """The census's lead: for each way of meeting, the share of pairs on each kind of path, then
    one line per pair."""
    first = [r for r in rows if r["scenario"].endswith("census · first contact")]
    if not first:
        return []
    after = {r["env"]: r for r in rows if r["scenario"].endswith("census · after 10 min idle")}
    lines = []
    for mode, label in (("census:link", "by link alone"), ("census:helper", "with a friend's relay"), ("census:reply", "by link, with a reply when it can't reach")):
        group = [r for r in first if r["scenario"].startswith(mode)]
        if not group:
            continue
        share = lambda kinds: f"{100 * sum(1 for r in group if r['path'] in kinds) / len(group):.0f}%"
        lines += [f"**Census, {label} ({len(group)} pairs{', port mapping off' if not MAPPING else ''}):** direct v6 {share({'v6'})}, direct v4 {share({'v4', 'punched'})}, "
                  f"mapped {share({'mapped'})}, LAN or VPN {share({'lan', 'vpn'})}, through a helper {share({'helper'})}, failed {share({'none'})}", "",
                  "| pair | path | first direct | after 10 min idle | packets/hour to the friend | note |", "|---|---|---|---|---|---|"]
        for r in group:
            a = after.get(r["env"], {})
            lines.append(f"| {r['env']} | {r['path']} | {fmt(r['secs']) or '—'} | {a.get('path', '—')}{'' if a.get('path') == r['path'] else ' (changed)'} | {(a.get('note') or '').split(' packets')[0]} | {r['note']} |")
        lines.append("")
    return lines


def report(rev, rows, started, path):
    lines = [f"# peer lab · {rev} · {started:%Y-%m-%d %H:%M}" + (f" · {WAN_DELAY} one-way on every link into the core" if WAN_DELAY else "") + ("" if MAPPING else " · port mapping off"), "",
             *census_summary(rows),
             "Real peer-node devices in Docker behind emulated routers (lab/README.md). `result`: pass, SLOW (worked, over target), FAIL.", "",
             "| scenario | environment | result | time | target | path | note |", "|---|---|---|---|---|---|---|"]
    for r in rows:
        lines.append(f"| {r['scenario']} | {r['env']} | {r['result']} | {fmt(r['secs'])} | {fmt(r['target'])} | {r['path']} | {r['note']} |")
    counts = {k: sum(1 for r in rows if r["result"] == k) for k in ("pass", "SLOW", "FAIL", "n/a")}
    lines += ["", f"{counts['pass']} pass · {counts['SLOW']} slow · {counts['FAIL']} fail · {counts['n/a']} observed", "",
              "Environments:", ""] + [f"- `{k}`: {v['what']}" for k, v in ENVS.items()]
    path.write_text("\n".join(lines) + "\n")
    return counts


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build"); b.add_argument("--rev", default="HEAD")
    r = sub.add_parser("run"); r.add_argument("--rev", default="HEAD"); r.add_argument("--only", default="")
    r.add_argument("--wan-delay", default=None, help="one-way delay on every link into the core (default 20ms; 0 for none)")
    r.add_argument("--no-mapping", action="store_true", help="no router offers port mapping (UPnP, NAT-PMP, PCP)")
    sub.add_parser("list")
    args = ap.parse_args()
    if args.cmd == "list":
        for k, v in SCENARIOS.items():
            print(k, "·", " ".join(v[0].__doc__.split()).split(".")[0])
        return
    global WAN_DELAY, MAPPING
    if getattr(args, "no_mapping", False):
        MAPPING = False
    if getattr(args, "wan_delay", None) is not None:
        WAN_DELAY = "" if args.wan_delay in ("0", "0ms", "") else args.wan_delay
    rev, binary = build(args.rev)
    if args.cmd == "build":
        print(binary)
        return
    started = datetime.datetime.now()
    names = [n for n in SCENARIOS if not args.only or any(n == o or n.startswith(o) for o in args.only.split(","))]
    stamp_dir = f"{rev}-{started:%Y%m%d-%H%M}" + (f"-wan{WAN_DELAY}" if WAN_DELAY else "")
    out_dir = LAB / "results"
    out_dir.mkdir(exist_ok=True)
    rows = []
    for i, name in enumerate(names):
        fn, *params = SCENARIOS[name]
        tag = f"{i:02d}"
        lab = Lab(binary, out_dir / "logs" / stamp_dir / name.replace(":", "_"), tag)
        print(f"[{i + 1}/{len(names)}] {name} …", flush=True)
        t0 = time.time()
        try:
            got = fn(lab, *params)
        except Exception as e:
            got = [row(name, " ".join(map(str, params[:2])) if params else "", False, note=f"lab error: {str(e).splitlines()[0][:120]}")]
        finally:
            lab.teardown()
        for g in got:
            g["scenario"] = f"{name} · {g['scenario']}"
            print(f"    {g['result']:5} {fmt(g['secs']):>8}  {g['scenario']}  {g['env']}  {g['path']}  {g['note']}", flush=True)
        rows += got
        print(f"    ({time.time() - t0:.0f} s)", flush=True)
        report(rev, rows, started, out_dir / f"{stamp_dir}.md")
    counts = report(rev, rows, started, out_dir / f"{stamp_dir}.md")
    print(f"\n{counts} → {out_dir / (stamp_dir + '.md')}")


if __name__ == "__main__":
    main()
