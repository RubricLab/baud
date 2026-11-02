//! `peer-node`: the crate as a headless device for a Mac mini or a Linux box that is online all
//! day. Keys in a 0600 file keychain under the data dir; everything else is the crate. `run`
//! stays online and takes commands on stdin, printing every event as it happens, so two nodes
//! in two terminals can walk journeys 1 and 2 by hand or by script.

use std::path::PathBuf;
use std::sync::Arc;

mod bench;
mod calls;
mod gate;
mod messages;

use clap::{Parser, Subcommand};
use peer::identity::FileKeychain;
use peer::{Config, Event, Listener, Peer};
use tokio::io::{AsyncBufReadExt, BufReader};

#[derive(Parser)]
#[command(name = "peer-node", about = "a headless peer device")]
struct Cli {
    /// Data directory (keys, store, blobs).
    #[arg(long, default_value = "~/.peer-node")]
    dir: String,
    /// The app this node belongs to: baud, computer, darkroom, life.
    #[arg(long, default_value = "baud")]
    app: String,
    /// What links look like before `#`; the app's. Default `<app>://add`.
    #[arg(long)]
    scheme: Option<String>,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Make the device key and a fresh person.
    Init {
        #[arg(long)]
        name: String,
    },
    /// Who I am, who I hold, how I am reached.
    Status,
    /// The network release gate: a fresh node with one contact, left alone for N minutes; every
    /// socket must point at a peer, this machine, localhost or mDNS. Root plus --capture adds tcpdump.
    Gate {
        #[arg(long, default_value_t = 10)]
        minutes: u64,
        #[arg(long)]
        capture: bool,
    },
    /// The latency table against a remote machine over ssh (scripts/bench.sh copies the binary
    /// there first). Fresh scratch nodes on both ends; nothing else on the remote is touched.
    Bench {
        /// ssh host of the remote (reachable) machine.
        #[arg(long)]
        remote: String,
        #[arg(long, default_value_t = 5)]
        runs: usize,
        /// Scenarios to run (default all but ipchange): cold, online, record, relaunch, dead, wake, message, blob, reimport, phantom, ipchange, relayed, own, chat, meet, own-relay, redirect.
        #[arg(long, value_delimiter = ',')]
        only: Vec<String>,
        #[arg(long, default_value_t = 60)]
        wake_secs: u64,
        #[arg(long, default_value_t = 100)]
        blob_mb: u64,
        /// Write the table here too.
        #[arg(long)]
        out: Option<PathBuf>,
        /// Local scratch for this side's nodes.
        #[arg(long)]
        scratch: Option<PathBuf>,
        /// The remote relay's port for the relayed scenario (a scratch relay, not one in use).
        #[arg(long, default_value_t = 4131)]
        relay_port: u16,
        /// The gateway grants no mapping: the remote relays are offered at their LAN address
        /// (`--public`), which this machine reaches on the same LAN. Off by default, so a mapping
        /// that stops working shows as a stopped topology.
        #[arg(long)]
        public_relays: bool,
    },
    /// Stay online. Prints events; reads commands on stdin:
    /// name <n> | invite | link-device | add <link> | link <link> | confirm <id> | post <petname> <text> | inbox | ack <id> | contacts | peers | records | status | tags <a,b> | online | offline | trace | group-new <space|chat> | group <id> <kind> | group-add <id> <petname> | members <id> | gpost <id> <name> <text> | send <petname> <text> | call <petname> | hangup | callstat | quit
    Run {
        /// Name for a brand-new node.
        #[arg(long, default_value = "")]
        name: String,
        /// Accept device links without a person (a headless box is nobody's screen).
        #[arg(long)]
        auto_confirm_links: bool,
        /// Print a friend link at start.
        #[arg(long)]
        invite: bool,
        /// Print a device link at start.
        #[arg(long)]
        link_device: bool,
        /// Redeem a friend link at start.
        #[arg(long)]
        add: Option<String>,
        /// Become that person's device at start.
        #[arg(long)]
        link: Option<String>,
        /// Turn off mDNS (tests on one machine).
        #[arg(long)]
        no_nearby: bool,
        /// Fixed UDP port (and the relay's TCP port).
        #[arg(long)]
        port: Option<u16>,
        /// Run the embedded relay for cardholders on --port.
        #[arg(long)]
        relay: bool,
        /// The port is forwarded or the address is global: skip the probe and the mapping.
        #[arg(long)]
        public: bool,
        /// Advertise this relay URL instead of http://<ip>:<port>.
        #[arg(long)]
        relay_url: Option<String>,
        /// No UPnP/NAT-PMP/PCP mapping: stay unreachable, to test relaying.
        #[arg(long)]
        no_portmap: bool,
        /// Leave VPN addresses out of records and dials (a test switch for one tailnet).
        #[arg(long)]
        no_vpn: bool,
        /// Print the crate's timing log as it happens: one JSON line per milestone.
        #[arg(long)]
        trace: bool,
    },
}

fn rand_group() -> [u8; 32] {
    // 32 random bytes, by way of a fresh key: peer-node has no other source of randomness.
    peer::identity::Secret::generate().device_id().0
}

fn group_of(hex: &str) -> Option<peer::identity::GroupId> {
    peer::identity::DeviceId::from_hex(hex).ok().map(|d| peer::identity::GroupId(d.0))
}

fn expand(dir: &str) -> PathBuf {
    if let Some(rest) = dir.strip_prefix("~/") {
        if let Some(home) = std::env::var_os("HOME") {
            return PathBuf::from(home).join(rest);
        }
    }
    PathBuf::from(dir)
}

struct Printer(Peer, Arc<calls::Calls>, Arc<messages::Messages>, tokio::runtime::Handle);

impl Listener for Printer {
    fn on(&self, event: Event) {
        let p = &self.0;
        let who = |d: &peer::identity::DeviceId| {
            let name = p.contacts().into_iter().find(|c| c.devices.iter().any(|s| s.device == *d)).map(|c| c.name);
            let own = p.me().devices.iter().any(|x| x.id == *d);
            match (name, own) {
                (Some(n), _) => format!("{n}'s {}", d.short()),
                (None, true) => format!("my {}", d.short()),
                _ => d.short(),
            }
        };
        match event {
            Event::Online(d) => {
                let path = p.peers().into_iter().find(|s| s.device == d).map(|s| format!("{} {}", s.path, s.rtt_ms.map(|r| format!("{r} ms")).unwrap_or_default())).unwrap_or_default();
                println!("· online {} {path}", who(&d))
            }
            Event::Offline(d) => println!("· offline {}", who(&d)),
            Event::Dialing(d) => println!("· dialing {}", who(&d)),
            Event::PathChanged(d) => {
                let path = p.peers().into_iter().find(|s| s.device == d).map(|s| format!("{} {}", s.path, s.rtt_ms.map(|r| format!("{r} ms")).unwrap_or_default())).unwrap_or_default();
                println!("· path {} {path}", who(&d))
            }
            Event::ContactsChanged => println!("· contacts: {}", p.contacts().iter().map(|c| format!("{} ({} devices)", c.name, c.devices.len())).collect::<Vec<_>>().join(", ")),
            Event::MeChanged => println!("· me: {} with {} devices", p.me().name, p.me().devices.len()),
            Event::LinkRequest(id) => println!("· link request {}: device {} wants to be mine, code {} (confirm {})", id.0, p.link_request(id).map(|d| d.short()).unwrap_or_default(), p.link_code(id).unwrap_or_default(), id.0),
            Event::RecordChanged(d) => println!("· record {}", who(&d)),
            Event::Inbox(id) => {
                if let Some(e) = p.inbox().into_iter().find(|e| e.id == id) {
                    let via = match (&e.from, e.carried_by.first()) {
                        (Some(f), _) => format!("direct from {}", who(f)),
                        (None, Some(c)) => format!("carried by {}", who(c)),
                        _ => "carried".into(),
                    };
                    println!("· inbox {}: {:?} ({via})", peer::identity::hex_of(&id.0[..4]), String::from_utf8_lossy(&e.bytes));
                }
            }
            Event::Delivered(id) => println!("· delivered {}", peer::identity::hex_of(&id.0[..4])),
            Event::ReachabilityChanged(r) => println!("· reachable: {r:?}"),
            Event::NetworkChanged => println!("· network changed"),
            Event::Removed => println!("· removed: another of my devices removed this one (reset to start over)"),
            Event::ContactRedirected { from, to } => println!("· redirected {} → {}", from.short(), to.short()),
            Event::ContactRemoved(u) => println!("· contact removed me: {}", u.short()),
            Event::Replied(u) => println!("· replied {}", u.short()),
            Event::PathMoved(d) => {
                let path = p.peers().into_iter().find(|s| s.device == d).map(|s| format!("{} {}", s.path, s.rtt_ms.map(|r| format!("{r} ms")).unwrap_or_default())).unwrap_or_default();
                println!("· moved {} {path}", who(&d))
            }
            Event::ReplyLapsed(u) => println!("· reply lapsed {}", u.short()),
            Event::Inbound { conn, alpn } if alpn.as_bytes() == calls::ALPN => {
                let (p, calls) = (p.clone(), self.1.clone());
                self.3.spawn(async move { calls.answer(&p, conn).await });
            }
            Event::Inbound { conn, alpn } if alpn.as_bytes() == messages::ALPN => {
                let (p, messages) = (p.clone(), self.2.clone());
                self.3.spawn(async move { messages.accept(&p, conn).await });
            }
            other => println!("· {other:?}"),
        }
    }
}

fn print_status(p: &Peer) {
    let me = p.me();
    println!("{} · {} · device {}", me.name, me.fingerprint, me.this_device);
    println!("devices: {}", me.devices.iter().map(|d| format!("{} {}", d.name, d.id.short())).collect::<Vec<_>>().join(", "));
    println!("reachable: {:?} ({:?})", p.reachable(), p.reachability());
    let h = p.helping();
    println!("relay: {}", h.relay_url.unwrap_or_else(|| "none".into()));
    println!("addresses: {}", p.addr().ip_addrs().map(|a| a.to_string()).chain(p.addr().relay_urls().map(|u| format!("relay={u}"))).collect::<Vec<_>>().join(" "));
    for c in p.contacts() {
        println!("contact {} {}{}", c.name, c.user.short(), if c.verified { " verified" } else { "" });
        for s in c.devices {
            println!("  {} {} {}", s.device.short(), s.path, s.rtt_ms.map(|r| format!("{r} ms")).unwrap_or_default());
        }
    }
    for r in p.records() {
        println!("record {} seq {} age {} s via {:?} reachable {:?}", r.device.short(), r.seq, r.age_ms / 1000, r.found_by, r.reachable);
    }
    let h = p.helping();
    println!("helping: {} envelopes, {} of {} bytes, {} records cached", h.envelopes, h.bytes, h.budget_bytes, h.records_cached);
    println!("inbox: {}, outbox: {}", p.inbox().len(), p.outbox().len());
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt().with_env_filter(tracing_subscriber::EnvFilter::from_default_env()).with_writer(std::io::stderr).init();
    let cli = Cli::parse();
    let dir = expand(&cli.dir);
    let keychain = Arc::new(FileKeychain(dir.join("keys")));
    let host = std::env::var("HOSTNAME").ok().or_else(|| std::process::Command::new("hostname").arg("-s").output().ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())).filter(|h| !h.is_empty()).unwrap_or_else(|| "node".into());
    let prefix = cli.scheme.clone().unwrap_or_else(|| format!("{}://add", cli.app));
    match cli.cmd {
        Cmd::Init { name } => {
            let p = Peer::open(dir.clone(), keychain.clone(), Config::new(&cli.app, &name, &host)).await?;
            let me = p.me();
            println!("{}\n{}\ndevice {}", me.name, me.fingerprint, me.this_device);
            p.close().await;
        }
        Cmd::Gate { minutes, capture } => {
            let ok = gate::run(gate::GateOpts { minutes, capture, app: cli.app.clone() }).await?;
            if !ok {
                std::process::exit(1);
            }
        }
        Cmd::Bench { remote, runs, only, wake_secs, blob_mb, out, scratch, relay_port, public_relays } => {
            let scratch = scratch.unwrap_or_else(|| std::env::temp_dir().join("peer-bench"));
            let ok = bench::run(bench::BenchOpts { remote, runs, only, wake_secs, blob_mb, out, scratch, relay_port, public_relays }).await?;
            if !ok {
                std::process::exit(1);
            }
        }
        Cmd::Status => {
            let p = Peer::open(dir.clone(), keychain.clone(), Config::new(&cli.app, "", &host)).await?;
            print_status(&p);
            p.close().await;
        }
        Cmd::Run { name, auto_confirm_links, invite, link_device, add, link, no_nearby, port, relay, public, relay_url, no_portmap, no_vpn, trace } => {
            let mut config = Config::new(&cli.app, &name, &host);
            config.link_scheme = prefix.clone();
            config.auto_confirm_links = auto_confirm_links;
            config.nearby = !no_nearby;
            config.port = port;
            config.relay = relay;
            config.public = public;
            config.relay_url = relay_url;
            config.portmap = !no_portmap;
            config.vpn = !no_vpn;
            config.alpns = vec![calls::ALPN.to_vec(), messages::ALPN.to_vec()];
            let p = Peer::open(dir.clone(), keychain.clone(), config).await?;
            let calls = Arc::new(calls::Calls::default());
            let messages = Arc::new(messages::Messages::default());
            if trace {
                for line in p.trace() {
                    println!("{line}");
                }
                p.set_trace_sink(Some(Arc::new(|line: &str| println!("{line}"))));
            }
            p.subscribe(Arc::new(Printer(p.clone(), calls.clone(), messages.clone(), tokio::runtime::Handle::current())));
            p.set_online(true);
            let me = p.me();
            println!("online as {} · device {} · {}", me.name, me.this_device.short(), p.addr().ip_addrs().map(|a| a.to_string()).collect::<Vec<_>>().join(" "));
            let h = p.helping();
            if h.relaying {
                println!("relaying for cardholders at {}", h.relay_url.unwrap_or_default());
            }
            if invite {
                println!("invite: {}", peer::link::format(&p.invite()?, &prefix));
            }
            if link_device {
                println!("device link: {}", peer::link::format(&p.link_device()?, &prefix));
            }
            if let Some(l) = add {
                match p.add(&peer::link::parse(&l)?).await {
                    Ok(c) => println!("added {}", c.name),
                    Err(e) => println!("add failed: {e}"),
                }
            }
            if let Some(l) = link {
                match p.link(&peer::link::parse(&l)?, &host).await {
                    Ok(()) => println!("linked: now {}", p.me().name),
                    Err(e) => println!("link failed: {e}"),
                }
            }
            let mut lines = BufReader::new(tokio::io::stdin()).lines();
            loop {
                let line = tokio::select! {
                    l = lines.next_line() => match l? { Some(l) => l, None => { tokio::signal::ctrl_c().await?; break } },
                    _ = tokio::signal::ctrl_c() => break,
                };
                let line = line.trim();
                let (cmd, arg) = line.split_once(' ').unwrap_or((line, ""));
                let r: Result<(), peer::Error> = match cmd {
                    "" => Ok(()),
                    "name" => p.set_name(arg),
                    "invite" => p.invite().map(|l| println!("invite: {}", peer::link::format(&l, &prefix))),
                    "link-device" => p.link_device().map(|l| println!("device link: {}", peer::link::format(&l, &prefix))),
                    "meeting" => {
                        // What the next link names, and whether this node is homed on its relay yet.
                        let m = p.invite_meeting();
                        let theirs: Vec<String> = match m.device {
                            Some(d) if d == p.me().this_device => p.helping().relay_url.unwrap_or_default().split(' ').map(str::to_owned).collect(),
                            Some(d) => p.record_addr(d).map(|a| a.relay_urls().map(|u| u.to_string()).collect()).unwrap_or_default(),
                            None => Vec::new(),
                        };
                        let homed = p.addr().relay_urls().any(|u| theirs.contains(&u.to_string()));
                        println!("meeting: {:?} {} {:?} of {:?} {}", m.kind, m.device.map(|d| d.short()).unwrap_or_else(|| "-".into()), m.device_name, m.user_name, if homed { "homed" } else { "not-homed" });
                        Ok(())
                    }
                    "redirects" => {
                        for r in p.redirects() {
                            println!("redirect {} → {}", r.from.short(), r.to.short());
                        }
                        println!("{} redirects", p.redirects().len());
                        Ok(())
                    }
                    "remove-device" => match p.me().devices.into_iter().find(|d| !arg.is_empty() && d.id.to_hex().starts_with(arg)) {
                        Some(d) => p.remove_device(d.id).map(|()| println!("removed {} {}", d.name, d.id.short())),
                        None => Err(peer::Error::NotFound),
                    },
                    "reset" => {
                        p.reset().await?;
                        println!("reset: keys and store deleted");
                        break;
                    }
                    "add" => match peer::link::parse(arg) {
                        Ok(l) => p.add(&l).await.map(|c| println!("added {}", c.name)),
                        Err(e) => Err(e),
                    },
                    // The add as an app makes it: in the background, so `reply` can follow it.
                    "add-bg" => peer::link::parse(arg).map(|l| {
                        let p = p.clone();
                        tokio::spawn(async move {
                            match p.add(&l).await {
                                Ok(c) => println!("added {}", c.name),
                                Err(e) => println!("add failed: {e}"),
                            }
                        });
                    }),
                    "reply" => peer::link::parse(arg).and_then(|l| p.reply(&l)).map(|r| println!("reply: {}", p.link_url(&r))),
                    "link" => match peer::link::parse(arg) {
                        Ok(l) => p.link(&l, &host).await.map(|()| println!("linked: now {}", p.me().name)),
                        Err(e) => Err(e),
                    },
                    "confirm" => arg.parse().map_err(|_| peer::Error::Encoding).and_then(|id| p.confirm_link(peer::LinkReqId(id), true)),
                    "contacts" => {
                        for c in p.contacts() {
                            println!("{} {} devices {}", c.name, c.user.short(), c.devices.iter().map(|s| format!("{}:{}", s.device.short(), s.path)).collect::<Vec<_>>().join(" "));
                        }
                        Ok(())
                    }
                    "peers" => {
                        for s in p.peers() {
                            println!("{} {} {} {}", s.device.short(), if s.online { "online" } else { "offline" }, s.path, s.rtt_ms.map(|r| format!("{r} ms")).unwrap_or_default());
                        }
                        Ok(())
                    }
                    "nearby" => {
                        for d in p.nearby() {
                            println!("nearby {}", d.short());
                        }
                        println!("{} nearby", p.nearby().len());
                        Ok(())
                    }
                    "records" => {
                        for r in p.records() {
                            println!("{} seq {} age {} s via {:?}", r.device.short(), r.seq, r.age_ms / 1000, r.found_by);
                        }
                        Ok(())
                    }
                    "status" => {
                        print_status(&p);
                        Ok(())
                    }
                    "probe" => {
                        println!("reachable: {:?}", p.probe().await);
                        Ok(())
                    }
                    "post" => {
                        let (name, text) = arg.split_once(' ').unwrap_or((arg, ""));
                        match p.contacts().into_iter().find(|c| c.name == name) {
                            Some(c) => {
                                for d in c.devices {
                                    match p.post(d.device, text.as_bytes().to_vec(), std::time::Duration::from_secs(14 * 86400)).await {
                                        Ok(id) => println!("posted {} to {}'s {}: {}", peer::identity::hex_of(&id.0[..4]), c.name, d.device.short(), if p.outbox().contains(&id) { "held, carriers will get it" } else { "delivered" }),
                                        Err(e) => println!("post to {} failed: {e}", d.device.short()),
                                    }
                                }
                                Ok(())
                            }
                            None => Err(peer::Error::NotFound),
                        }
                    }
                    "blob-add-dir" => {
                        // Every file in the directory at once, as an app providing its library does.
                        let files: Vec<std::path::PathBuf> = std::fs::read_dir(arg).map(|r| r.filter_map(|e| e.ok().map(|e| e.path())).filter(|f| f.is_file()).collect()).unwrap_or_default();
                        // This process's open files, counted every millisecond while they import.
                        let open = || std::fs::read_dir("/dev/fd").map(|d| d.count()).unwrap_or(0);
                        let base = open();
                        let most = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(base));
                        let sampler = {
                            let most = most.clone();
                            tokio::spawn(async move {
                                loop {
                                    most.fetch_max(open(), std::sync::atomic::Ordering::Relaxed);
                                    tokio::time::sleep(std::time::Duration::from_millis(1)).await;
                                }
                            })
                        };
                        let mut set = tokio::task::JoinSet::new();
                        for f in files {
                            let p = p.clone();
                            set.spawn(async move { p.blobs().add_path(&f).await });
                        }
                        let (mut ok, mut failed) = (0, 0);
                        while let Some(r) = set.join_next().await {
                            if matches!(r, Ok(Ok(_))) { ok += 1 } else { failed += 1 }
                        }
                        sampler.abort();
                        let extra = most.load(std::sync::atomic::Ordering::Relaxed).saturating_sub(base);
                        println!("blobs {ok} added, {failed} failed, {extra} more files open at most");
                        Ok(())
                    }
                    "blob-add" => match p.blobs().add_path(std::path::Path::new(arg)).await {
                        Ok(h) => {
                            println!("blob {}", h.to_hex());
                            Ok(())
                        }
                        Err(e) => Err(e),
                    },
                    "fetch" => {
                        let parts: Vec<&str> = arg.split_whitespace().collect();
                        if parts.len() != 3 {
                            println!("fetch <petname> <hash> <to>");
                            Ok(())
                        } else {
                            let device = p.contacts().into_iter().find(|c| c.name == parts[0]).and_then(|c| c.devices.into_iter().map(|d| d.device).next()).ok_or(peer::Error::NotFound)?;
                            let hash = peer::blobs::Hash::from_hex(parts[1])?;
                            p.blobs().fetch(device, hash, std::path::Path::new(parts[2]), None).await.map(|t| println!("fetching {} from {}: {:?}", parts[1], parts[0], t.state()))
                        }
                    }
                    "pause" | "resume" | "cancel" => {
                        for t in p.blobs().transfers() {
                            match cmd {
                                "pause" => t.pause(),
                                "resume" => t.resume(),
                                _ => t.cancel(),
                            }
                        }
                        Ok(())
                    }
                    "transfers" => {
                        for t in p.blobs().transfers() {
                            let (done, total) = t.progress();
                            println!("{} {:?} {} / {} bytes", t.hash().to_hex()[..8].to_owned(), t.state(), done, total);
                        }
                        Ok(())
                    }
                    "inbox" => {
                        for e in p.inbox() {
                            println!("{} {:?} carried by {:?} from {:?}", peer::identity::hex_of(&e.id.0[..4]), String::from_utf8_lossy(&e.bytes), e.carried_by.iter().map(|d| d.short()).collect::<Vec<_>>(), e.from.map(|d| d.short()));
                        }
                        Ok(())
                    }
                    "ack" => {
                        let id = p.inbox().into_iter().find(|e| peer::identity::hex_of(&e.id.0[..4]) == arg).map(|e| e.id).ok_or(peer::Error::NotFound)?;
                        p.ack(id)
                    }
                    "group-new" => {
                        let kind = if arg == "chat" { peer::GroupKind::Chat } else { peer::GroupKind::Space };
                        let g = peer::identity::GroupId(rand_group());
                        p.create_group(g, kind).map(|()| println!("group {} {kind:?}", peer::identity::hex_of(&g.0)))
                    }
                    "group" => {
                        let (g, kind) = arg.split_once(' ').unwrap_or((arg, "space"));
                        match group_of(g) {
                            Some(g) => p.create_group(g, if kind == "chat" { peer::GroupKind::Chat } else { peer::GroupKind::Space }).map(|()| println!("in group {}", peer::identity::hex_of(&g.0[..4]))),
                            None => Err(peer::Error::Encoding),
                        }
                    }
                    "group-add" => {
                        let (g, name) = arg.split_once(' ').unwrap_or((arg, ""));
                        let card = p.contacts().into_iter().find(|c| c.name == name).and_then(|c| c.card);
                        match (group_of(g), card) {
                            (Some(g), Some(card)) => p.add_member(g, card).map(|()| println!("added {name} to {}", peer::identity::hex_of(&g.0[..4]))),
                            _ => Err(peer::Error::NotFound),
                        }
                    }
                    "members" => match group_of(arg) {
                        Some(g) => {
                            for m in p.group_members(g) {
                                println!("member {} {}{}", m.name, if m.contact { "contact" } else { "not a contact" }, if m.mutual { ", mutual" } else { "" });
                            }
                            Ok(())
                        }
                        None => Err(peer::Error::Encoding),
                    },
                    "gpost" => {
                        // gpost <group> <member's public name> <text>: to a co-member, contact or not.
                        let mut parts = arg.splitn(3, ' ');
                        let (g, name, text) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""), parts.next().unwrap_or(""));
                        match group_of(g).and_then(|g| p.group_members(g).into_iter().find(|m| m.name == name)) {
                            Some(m) => {
                                for d in m.card.device_ids() {
                                    match p.post(d, text.as_bytes().to_vec(), std::time::Duration::from_secs(14 * 86400)).await {
                                        Ok(id) => println!("posted {} to {name}'s {}: {}", peer::identity::hex_of(&id.0[..4]), d.short(), if p.outbox().contains(&id) { "held, carriers will get it" } else { "delivered" }),
                                        Err(e) => println!("post to {} failed: {e}", d.short()),
                                    }
                                }
                                Ok(())
                            }
                            None => Err(peer::Error::NotFound),
                        }
                    }
                    "tags" => p.set_tags(arg.split(',').map(str::trim).filter(|t| !t.is_empty()).map(str::to_owned).collect()),
                    "online" => {
                        p.set_online(true);
                        Ok(())
                    }
                    "offline" => {
                        p.set_online(false);
                        Ok(())
                    }
                    "trace" => {
                        for line in p.trace() {
                            println!("{line}");
                        }
                        Ok(())
                    }
                    "burst" => {
                        // burst <name> <n>: n envelopes at once, as an app posting many frames does.
                        let (name, n) = arg.split_once(' ').unwrap_or((arg, "100"));
                        let (n, d) = (n.parse::<usize>().unwrap_or(100), p.contacts().into_iter().find(|c| c.name == name).and_then(|c| c.devices.first().map(|d| d.device)));
                        match d {
                            Some(d) => {
                                let p = p.clone();
                                tokio::spawn(async move {
                                    let t = std::time::Instant::now();
                                    let posts: Vec<_> = (0..n).map(|i| { let p = p.clone(); tokio::spawn(async move { p.post(d, format!("burst{i}").into_bytes(), std::time::Duration::from_secs(14 * 86400)).await }) }).collect();
                                    let mut failed = 0;
                                    for x in posts {
                                        if !matches!(x.await, Ok(Ok(_))) {
                                            failed += 1;
                                        }
                                    }
                                    println!("burst posted {} in {} ms, {failed} failed, {} still mine", n, t.elapsed().as_millis(), p.outbox().len());
                                });
                                Ok(())
                            }
                            None => Err(peer::Error::NotFound),
                        }
                    }
                    "send" => {
                        let (name, text) = arg.split_once(' ').unwrap_or((arg, ""));
                        let (p, messages, name, text) = (p.clone(), messages.clone(), name.to_owned(), text.to_owned());
                        tokio::spawn(async move { messages.send(&p, &name, &text).await });
                        Ok(())
                    }
                    "call" => {
                        let (p, calls, name) = (p.clone(), calls.clone(), arg.to_owned());
                        tokio::spawn(async move { calls.dial(&p, &name).await });
                        Ok(())
                    }
                    "hangup" => {
                        let calls = calls.clone();
                        tokio::spawn(async move { calls.hang_up().await });
                        Ok(())
                    }
                    "callstat" => {
                        calls.stat();
                        Ok(())
                    }
                    "quit" => break,
                    other => {
                        println!("? {other}");
                        Ok(())
                    }
                };
                if let Err(e) = r {
                    println!("error: {e}");
                }
            }
            p.close().await;
        }
    }
    Ok(())
}
