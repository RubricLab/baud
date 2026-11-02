//! `peer-node gate`: the network release gate (DESIGN.md rule 1), rootless. A fresh node A
//! runs in this process with one contact B in a child `peer-node`; they join by invite and are
//! left alone for N minutes while every socket of A is sampled with `nettop` (macOS) or `ss`
//! (Linux). The gate passes when every TCP remote and every connected UDP peer is localhost,
//! link-local, mDNS multicast, this machine, or an address B advertised. `--capture` adds the
//! packet-level proof with `tcpdump` when run as root: every destination in the capture must
//! pass the same test. Copied from darkroom's `scripts/release/netgate.sh`.

use std::collections::{BTreeMap, BTreeSet};
use std::io::{BufRead, BufReader};
use std::net::IpAddr;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

use peer::identity::FileKeychain;
use peer::{Config, Peer};

pub struct GateOpts {
    pub minutes: u64,
    pub capture: bool,
    pub app: String,
}

pub async fn run(opts: GateOpts) -> Result<bool, Box<dyn std::error::Error>> {
    let work = tempfile::tempdir()?;
    let exe = std::env::current_exe()?;
    // B: the one contact, a child process so A's inventory is A's alone.
    let mut b = Command::new(&exe)
        .args(["--dir", work.path().join("b").to_str().unwrap(), "--app", &opts.app, "run", "--name", "contact", "--invite"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let b_out = b.stdout.take().unwrap();
    let mut lines = BufReader::new(b_out).lines();
    let invite = {
        let mut link = None;
        for line in lines.by_ref().take(40) {
            let line = line?;
            if let Some(l) = line.strip_prefix("invite: ") {
                link = Some(l.to_owned());
                break;
            }
        }
        link.ok_or("the contact printed no invite")?
    };
    // Keep draining B's output: a closed pipe would kill it on its next line.
    std::thread::spawn(move || for _ in lines {});
    // A: under test, here.
    let mut config = Config::new(&opts.app, "gate", "gate-dev");
    config.auto_confirm_links = false;
    let a = Peer::open(work.path().join("a"), Arc::new(FileKeychain(work.path().join("a-keys"))), config).await?;
    a.set_online(true);
    let contact = a.add(&peer::link::parse(&invite)?).await?;
    let b_device = contact.devices.first().map(|d| d.device).ok_or("contact has no device")?;
    for _ in 0..100 {
        if a.contacts().iter().any(|c| c.devices.iter().any(|d| d.online)) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let path = a.contacts()[0].devices[0].path;
    println!("▸ A pid {} under test, contact pid {} · {} · {} min{}", std::process::id(), b.id(), path, opts.minutes, if opts.capture { " · capture" } else { "" });

    let pcap = work.path().join("gate.pcap");
    let mut dump = if opts.capture {
        match Command::new("tcpdump").args(["-i", "any", "-nn", "-q", "-w", pcap.to_str().unwrap(), "udp or tcp"]).stdout(Stdio::null()).stderr(Stdio::null()).spawn() {
            Ok(c) => Some(c),
            Err(e) => {
                println!("  capture unavailable ({e}); run as root for the packet-level proof");
                None
            }
        }
    } else {
        None
    };

    let mut tcp_remotes: BTreeMap<String, u32> = BTreeMap::new();
    let mut udp_sockets: BTreeMap<String, u32> = BTreeMap::new();
    let end = Instant::now() + Duration::from_secs(opts.minutes * 60);
    let mut samples = 0u32;
    while Instant::now() < end {
        if let Some((t, u)) = sample(std::process::id()) {
            for r in t {
                *tcp_remotes.entry(r).or_default() += 1;
            }
            for s in u {
                *udp_sockets.entry(s).or_default() += 1;
            }
        }
        samples += 1;
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
    if let Some(d) = dump.as_mut() {
        let _ = Command::new("kill").args(["-INT", &d.id().to_string()]).status();
        let _ = d.wait();
    }

    // The allow-list: this machine, localhost, link-local, mDNS, and every address B advertised.
    let mut allowed: BTreeSet<IpAddr> = my_ips();
    // The LAN gateway: UPnP, NAT-PMP and PCP talk to it, as the directive's probe section allows.
    if let Some(gw) = gateway() {
        allowed.insert(gw);
    }
    if let Some(addr) = a.record_addr(b_device) {
        allowed.extend(addr.ip_addrs().map(|a| a.ip()));
    }
    let ok_host = |h: &str| -> bool {
        let h = h.trim_start_matches('[').trim_end_matches(']');
        match h.parse::<IpAddr>() {
            Ok(ip) => ip.is_loopback() || ip.is_multicast() || allowed.contains(&ip) || matches!(ip, IpAddr::V6(v) if v.is_unicast_link_local()) || matches!(ip, IpAddr::V4(v) if v.is_link_local()),
            Err(_) => h == "*" || h.is_empty(),
        }
    };
    println!("▸ {samples} samples · TCP remotes (count, host:port):");
    let mut bad = Vec::new();
    for (r, n) in &tcp_remotes {
        println!("  {n:5} {r}");
        if !ok_host(&host_of(r)) {
            bad.push(format!("tcp -> {r}"));
        }
    }
    println!("▸ UDP sockets (count, local [-> remote]):");
    let (mut persistent, mut transient) = (0, 0);
    for (s, n) in &udp_sockets {
        let lasting = *n * 2 >= samples;
        println!("  {n:5} {s}{}", if !lasting && !s.contains("5353") { "   (transient: port mapping)" } else { "" });
        match s.split_once(" -> ") {
            Some((_, remote)) => {
                if !ok_host(&host_of(remote)) {
                    bad.push(format!("udp -> {remote}"));
                }
            }
            None if !s.contains(":5353") && !s.contains(".5353") => {
                if lasting { persistent += 1 } else { transient += 1 }
            }
            None => {}
        }
    }
    // The endpoint owns one v4 and one v6 socket for the whole run; a third that lasts is a
    // resolver or a discovery client. A short-lived one is the port mapper asking the gateway.
    if persistent > 2 {
        bad.push(format!("{persistent} lasting UDP sockets besides mDNS (the endpoint has two)"));
    }
    if transient > 0 {
        println!("  {transient} transient UDP socket(s): the port mapper (UPnP, NAT-PMP, PCP to the gateway), allowed");
    }
    if opts.capture && pcap.exists() {
        let out = Command::new("tcpdump").args(["-nn", "-q", "-r", pcap.to_str().unwrap()]).output()?;
        let mut dests: BTreeMap<String, u32> = BTreeMap::new();
        for line in String::from_utf8_lossy(&out.stdout).lines() {
            if let Some(i) = line.find(" > ") {
                let dst = line[i + 3..].split([':', ' ']).next().unwrap_or("").to_owned();
                *dests.entry(host_of(&dst)).or_default() += 1;
            }
        }
        println!("▸ capture destinations (count, host):");
        for (h, n) in &dests {
            println!("  {n:5} {h}");
            if !ok_host(h) {
                bad.push(format!("packet -> {h}"));
            }
        }
    } else if !opts.capture {
        println!("  (UDP datagram destinations are not visible without BPF; run as root with --capture for the packet-level proof.)");
    }
    a.close().await;
    // `quit`, not a kill: a killed node cannot give its port mapping back to the gateway.
    if let Some(mut stdin) = b.stdin.take() {
        use std::io::Write;
        let _ = stdin.write_all(b"quit\n");
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline && matches!(b.try_wait(), Ok(None)) {
        std::thread::sleep(Duration::from_millis(100));
    }
    let _ = b.kill();
    let _ = b.wait();
    if bad.is_empty() {
        println!("✓ PASS: nothing left for a non-peer host in {} minutes ({} samples)", opts.minutes, samples);
        Ok(true)
    } else {
        println!("✗ FAIL:");
        for l in &bad {
            println!("  {l}");
        }
        Ok(false)
    }
}

/// Strip the port: `1.2.3.4:5` and `1.2.3.4.5` (nettop) and `[v6]:5`.
fn host_of(s: &str) -> String {
    let s = s.trim();
    if let Some(rest) = s.strip_prefix('[') {
        return rest.split(']').next().unwrap_or("").to_owned();
    }
    if s.matches('.').count() == 4 {
        return s.rsplit_once('.').map(|(h, _)| h.to_owned()).unwrap_or_default();
    }
    if s.matches(':').count() == 1 {
        return s.split(':').next().unwrap_or("").to_owned();
    }
    s.to_owned()
}

fn gateway() -> Option<IpAddr> {
    if cfg!(target_os = "macos") {
        let out = Command::new("route").args(["-n", "get", "default"]).output().ok()?;
        String::from_utf8_lossy(&out.stdout).lines().find_map(|l| l.trim().strip_prefix("gateway: ").and_then(|g| g.trim().parse().ok()))
    } else {
        let out = Command::new("ip").args(["route", "show", "default"]).output().ok()?;
        String::from_utf8_lossy(&out.stdout).split_whitespace().skip_while(|w| *w != "via").nth(1).and_then(|g| g.parse().ok())
    }
}

fn my_ips() -> BTreeSet<IpAddr> {
    let out = Command::new("ifconfig").output().ok().map(|o| String::from_utf8_lossy(&o.stdout).into_owned()).unwrap_or_default();
    let mut set = BTreeSet::new();
    for line in out.lines() {
        let t = line.trim();
        if let Some(rest) = t.strip_prefix("inet ").or_else(|| t.strip_prefix("inet6 ")) {
            if let Some(ip) = rest.split_whitespace().next().and_then(|a| a.split('%').next()).and_then(|a| a.parse().ok()) {
                set.insert(ip);
            }
        }
    }
    set
}

/// One inventory: TCP remotes and UDP sockets (`local [-> remote]`) of `pid`.
fn sample(pid: u32) -> Option<(Vec<String>, Vec<String>)> {
    if cfg!(target_os = "macos") {
        let out = Command::new("nettop").args(["-L", "1", "-n", "-J", "interface,state", "-p", &pid.to_string()]).output().ok()?;
        let (mut tcp, mut udp) = (Vec::new(), Vec::new());
        for line in String::from_utf8_lossy(&out.stdout).lines() {
            let first = line.split(',').next().unwrap_or("");
            if let Some(rest) = first.strip_prefix("tcp4 ").or_else(|| first.strip_prefix("tcp6 ")) {
                if let Some((_, remote)) = rest.split_once("<->") {
                    if remote != "*:*" {
                        tcp.push(remote.to_owned());
                    }
                }
            } else if let Some(rest) = first.strip_prefix("udp4 ").or_else(|| first.strip_prefix("udp6 ")) {
                if let Some((local, remote)) = rest.split_once("<->") {
                    udp.push(if remote == "*:*" || remote == "*.*" { local.to_owned() } else { format!("{local} -> {remote}") });
                }
            }
        }
        Some((tcp, udp))
    } else {
        let out = Command::new("ss").args(["-tunpH"]).output().ok()?;
        let (mut tcp, mut udp) = (Vec::new(), Vec::new());
        let tag = format!("pid={pid},");
        for line in String::from_utf8_lossy(&out.stdout).lines() {
            if !line.contains(&tag) {
                continue;
            }
            let cols: Vec<&str> = line.split_whitespace().collect();
            if cols.len() < 6 {
                continue;
            }
            match cols[0] {
                "tcp" if cols[5] != "*:*" => tcp.push(cols[5].to_owned()),
                "udp" => udp.push(if cols[5] == "*:*" { cols[4].to_owned() } else { format!("{} -> {}", cols[4], cols[5]) }),
                _ => {}
            }
        }
        Some((tcp, udp))
    }
}
