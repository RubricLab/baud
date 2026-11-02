//! Port mappings the crate owns (iroh's own port mapper is off). Kept for as long as the node
//! runs, renewed at half their lease, removed on `close`, and asked for on the same external port
//! next time, so a node that restarts all day keeps one mapping and peers' cached addresses stay
//! good. iroh asks for a new external port on every start and never releases the old one; a Mac
//! that relaunched often filled a home router's table that way.
//!
//! UPnP goes through igd-next directly: the only way to name the external port, list the table
//! and delete an entry. A start first removes this node's own leftovers (same internal address,
//! port and protocol, under this description or iroh's), which is what a crash leaves. NAT-PMP
//! and PCP go through `portmapper` with UPnP off, kept alive so it renews and releases. Which one
//! a gateway speaks is asked both ways at once (`speaks`): a router with only NAT-PMP or PCP
//! answers in milliseconds, and waiting out a silent UPnP search first cost a link minted in the
//! first seconds its port (3 s, the lab's NAT-PMP router).

use std::net::{IpAddr, Ipv4Addr, SocketAddr, SocketAddrV4};
use std::num::NonZeroU16;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use igd_next::aio::tokio as aigd;
use igd_next::PortMappingProtocol;
use tokio::sync::{oneshot, watch};

/// What the gateway last said when asked for a mapping, for a sentence the person can act on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum Gateway {
    /// Not asked yet, or asked through NAT-PMP/PCP, which say nothing more.
    Unknown,
    /// No UPnP gateway answered.
    None,
    /// A UPnP gateway answered without an internet side: no external address (Dexter's after an
    /// outage: "Unconfigured", uptime 0, every mapping "yes" and none held). A restart fixes it.
    NoInternet,
    /// It refused the mapping, or said yes and does not hold it.
    Refused,
    /// A mapping it holds.
    Mapped,
}

static LAST: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);

/// The gateway's last answer in this process.
pub fn gateway() -> Gateway {
    match LAST.load(std::sync::atomic::Ordering::Relaxed) {
        1 => Gateway::None,
        2 => Gateway::NoInternet,
        3 => Gateway::Refused,
        4 => Gateway::Mapped,
        _ => Gateway::Unknown,
    }
}

fn said(g: Gateway) {
    let v = match g {
        Gateway::Unknown => 0,
        Gateway::None => 1,
        Gateway::NoInternet => 2,
        Gateway::Refused => 3,
        Gateway::Mapped => 4,
    };
    LAST.store(v, std::sync::atomic::Ordering::Relaxed);
}

/// The description every mapping of ours carries; the sweep also takes iroh's.
pub const DESCRIPTION: &str = "peer";
const IROH_DESCRIPTION: &str = "iroh-portmap";
const LEASE_SECS: u32 = 3600;
const SEARCH: Duration = Duration::from_secs(3);
const RELEASE: Duration = Duration::from_secs(1);
/// How long a confirming request may take.
const CONFIRM: Duration = Duration::from_secs(3);
/// How long the first request may take before a link is minted without its answer.
pub const FIRST: Duration = Duration::from_secs(3);
/// A NAT-PMP or PCP yes waits this long for UPnP, which can name, list and delete mappings.
const UPNP_GRACE: Duration = Duration::from_millis(250);
/// How often a held mapping is confirmed between renewals: a router that restarts forgets every
/// mapping and says nothing (the lab's reboot; a half-lease renewal would notice after 30 min).
const CHECK: Duration = Duration::from_secs(60);
/// How long a lost mapping waits before the gateway is asked again from the start.
const RETRY: Duration = Duration::from_secs(5);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Proto {
    Udp,
    Tcp,
}

/// One mapping, alive while this is held. `external` says where it points from outside.
pub struct Mapping {
    pub external: watch::Receiver<Option<SocketAddrV4>>,
    stop: Option<oneshot::Sender<oneshot::Sender<()>>>,
    started: Instant,
    /// No gateway on this network to ask: nothing is coming.
    alone: Arc<AtomicBool>,
    /// Confirm now rather than at the next `CHECK` (`Mapping::check`).
    nudge: Arc<tokio::sync::Notify>,
}

impl Mapping {
    /// Ask the gateway for `local_port` (on `local_ip`), on `preferred` outside when it is free.
    pub fn start(proto: Proto, local_ip: Ipv4Addr, local_port: u16, preferred: Option<u16>) -> Mapping {
        let (tx, external) = watch::channel(None);
        let (stop, stopped) = oneshot::channel::<oneshot::Sender<()>>();
        let alone = Arc::new(AtomicBool::new(false));
        let nudge = Arc::new(tokio::sync::Notify::new());
        tokio::spawn(run(proto, local_ip, local_port, preferred, tx, stopped, alone.clone(), nudge.clone()));
        Mapping { external, stop: Some(stop), started: Instant::now(), alone, nudge }
    }

    /// Something suggests the router lost it (a held connection timed out): confirm it now.
    pub fn check(&self) {
        self.nudge.notify_one();
    }

    pub fn current(&self) -> Option<SocketAddrV4> {
        *self.external.borrow()
    }

    /// The first request has its answer: a mapping, no gateway to ask, or `FIRST` gone by.
    pub fn settled(&self) -> bool {
        self.current().is_some() || self.alone.load(Ordering::Relaxed) || self.started.elapsed() >= FIRST
    }

    /// The first mapping, within `limit`.
    pub async fn wait(&mut self, limit: Duration) -> Option<SocketAddrV4> {
        let mut rx = self.external.clone();
        tokio::time::timeout(limit, async move {
            loop {
                if let Some(a) = *rx.borrow() {
                    return Some(a);
                }
                if rx.changed().await.is_err() {
                    return None;
                }
            }
        })
        .await
        .ok()
        .flatten()
    }

    /// Remove it from the gateway now, waiting at most a second.
    pub async fn release(mut self) {
        if let Some(stop) = self.stop.take() {
            let (done, wait) = oneshot::channel();
            if stop.send(done).is_ok() {
                let _ = tokio::time::timeout(RELEASE + Duration::from_millis(200), wait).await;
            }
        }
    }
}

fn igd_proto(p: Proto) -> PortMappingProtocol {
    match p {
        Proto::Udp => PortMappingProtocol::UDP,
        Proto::Tcp => PortMappingProtocol::TCP,
    }
}

/// What a gateway speaks: UPnP (preferred: it can name, list and delete), else NAT-PMP or PCP.
enum Speaks {
    Upnp(igd_next::aio::Gateway<aigd::Tokio>),
    Pmp,
    Nothing,
}

/// Asked both ways at once: UPnP by a search sent to the gateway alone, NAT-PMP and PCP by
/// portmapper's probe (which maps nothing). A NAT-PMP or PCP yes still gives UPnP `UPNP_GRACE`.
async fn speaks(router: Ipv4Addr, proto: Proto) -> Speaks {
    // The search goes to the default gateway alone, not to the multicast group: every UPnP device
    // on a LAN answers that (a speaker, a TV), and fetching their descriptions is talking to hosts
    // that are not peers (DESIGN.md rule 1; the release gate caught it at home).
    let search = igd_next::SearchOptions { broadcast_address: SocketAddr::new(IpAddr::V4(router), 1900), timeout: Some(SEARCH), ..Default::default() };
    let upnp = async { tokio::time::timeout(SEARCH, aigd::search_gateway(search)).await.ok().and_then(|r| r.ok()).filter(|g| g.addr.ip() == IpAddr::V4(router)) };
    let prober = portmapper::Client::new(portmapper::Config { enable_upnp: false, protocol: pmp_protocol(proto), ..portmapper::Config::default() });
    let pmp = async { matches!(tokio::time::timeout(SEARCH, prober.probe()).await, Ok(Ok(Ok(p))) if p.pcp || p.nat_pmp) };
    tokio::pin!(upnp, pmp);
    let (mut upnp_said, mut pmp_said) = (false, None);
    loop {
        tokio::select! {
            g = &mut upnp, if !upnp_said => match g {
                Some(g) => return Speaks::Upnp(g),
                None => upnp_said = true,
            },
            yes = &mut pmp, if pmp_said.is_none() => pmp_said = Some(yes),
        }
        match (upnp_said, pmp_said) {
            (true, Some(yes)) => return if yes { Speaks::Pmp } else { Speaks::Nothing },
            (false, Some(true)) => {
                return match tokio::time::timeout(UPNP_GRACE, &mut upnp).await {
                    Ok(Some(g)) => Speaks::Upnp(g),
                    _ => Speaks::Pmp,
                };
            }
            _ => {}
        }
    }
}

fn pmp_protocol(proto: Proto) -> portmapper::Protocol {
    match proto {
        Proto::Udp => portmapper::Protocol::Udp,
        Proto::Tcp => portmapper::Protocol::Tcp,
    }
}

#[allow(clippy::too_many_arguments)]
async fn run(proto: Proto, local_ip: Ipv4Addr, local_port: u16, preferred: Option<u16>, tx: watch::Sender<Option<SocketAddrV4>>, mut stopped: oneshot::Receiver<oneshot::Sender<()>>, alone: Arc<AtomicBool>, nudge: Arc<tokio::sync::Notify>) {
    let Some(IpAddr::V4(router)) = netwatch::interfaces::HomeRouter::new().map(|h| h.gateway) else {
        alone.store(true, Ordering::Relaxed);
        return pmp(proto, local_port, tx, stopped, nudge).await;
    };
    // Once held, a UPnP mapping the gateway stops holding (it restarted, and may answer on
    // another control URL) is asked for again from the search, on the same external port.
    let mut preferred = preferred;
    loop {
        let gateway = match speaks(router, proto).await {
            Speaks::Upnp(g) => g,
            Speaks::Pmp => return pmp(proto, local_port, tx, stopped, nudge).await,
            Speaks::Nothing => {
                said(Gateway::None);
                alone.store(true, Ordering::Relaxed);
                return pmp(proto, local_port, tx, stopped, nudge).await;
            }
        };
        match upnp(gateway, proto, local_ip, local_port, preferred, &tx, &mut stopped, &nudge).await {
            Held::Stopped => return,
            Held::Lost(port) => {
                preferred = Some(port);
                tokio::select! {
                    done = &mut stopped => {
                        if let Ok(done) = done {
                            let _ = done.send(());
                        }
                        return;
                    }
                    _ = tokio::time::sleep(RETRY) => {}
                }
            }
            Held::Never => return pmp(proto, local_port, tx, stopped, nudge).await,
        }
    }
}

/// How a UPnP mapping ended: closed, lost by the gateway (on this external port), or never had.
enum Held {
    Stopped,
    Lost(u16),
    Never,
}

#[allow(clippy::too_many_arguments)]
async fn upnp(gateway: igd_next::aio::Gateway<aigd::Tokio>, proto: Proto, local_ip: Ipv4Addr, local_port: u16, preferred: Option<u16>, tx: &watch::Sender<Option<SocketAddrV4>>, stopped: &mut oneshot::Receiver<oneshot::Sender<()>>, nudge: &tokio::sync::Notify) -> Held {
    let local = SocketAddr::new(IpAddr::V4(local_ip), local_port);
    let p = igd_proto(proto);
    // Closed while the gateway was being found: map nothing.
    if let Ok(done) = stopped.try_recv() {
        let _ = tx.send(None);
        let _ = done.send(());
        return Held::Stopped;
    }
    // A crash left a mapping for exactly this address and port: take it back, or clear it away.
    let mut left = Vec::new();
    for i in 0..256u32 {
        let Ok(e) = gateway.get_generic_port_mapping_entry(i).await else { break };
        if e.protocol == p && e.internal_port == local_port && e.internal_client == local_ip.to_string() && (e.port_mapping_description == DESCRIPTION || e.port_mapping_description == IROH_DESCRIPTION) {
            left.push(e.external_port);
        }
    }
    // The local port outside first: a router's NAT sends the flows I start out from the port
    // they leave by when it is free, so mapped to that same number, a far side behind a carrier's
    // NAT (which hears only the address it sent to) hears flows I start too (a call to a phone on
    // cellular that reached me on the mapping). Then last time's, then a crash's leftover.
    let mut wants: Vec<u16> = Vec::new();
    for w in [Some(local_port), preferred.filter(|p| *p != 0), left.first().copied()].into_iter().flatten() {
        if !wants.contains(&w) {
            wants.push(w);
        }
    }
    for port in left.iter().filter(|l| !wants.contains(l)) {
        let _ = gateway.remove_port(p, *port).await;
    }
    let external_ip = match gateway.get_external_ip().await {
        Ok(IpAddr::V4(ip)) if !ip.is_unspecified() => ip,
        _ => {
            said(Gateway::NoInternet);
            return Held::Never;
        }
    };
    let mut port = None;
    for w in &wants {
        if gateway.add_port(p, *w, local, LEASE_SECS, DESCRIPTION).await.is_ok() {
            port = Some(*w);
            break;
        }
    }
    if port.is_none() {
        port = gateway.add_any_port(p, local, LEASE_SECS, DESCRIPTION).await.ok();
    }
    for l in left.iter().filter(|l| wants.contains(l) && Some(**l) != port) {
        let _ = gateway.remove_port(p, *l).await;
    }
    let Some(port) = port else {
        said(Gateway::Refused);
        return Held::Never;
    };
    // A gateway's yes is not a mapping: one that answers success and stores nothing (the home
    // router after an outage did) would have us advertise an address nobody can reach.
    if !upnp_holds(&gateway, p, port, local).await {
        tracing::warn!("the gateway said yes to {proto:?} {port} but does not hold it: not advertised");
        let _ = gateway.remove_port(p, port).await;
        said(Gateway::Refused);
        return Held::Never;
    }
    // Closed while the mapping was being asked for: give it straight back.
    if let Ok(done) = stopped.try_recv() {
        let _ = gateway.remove_port(p, port).await;
        let _ = tx.send(None);
        let _ = done.send(());
        return Held::Stopped;
    }
    said(Gateway::Mapped);
    let _ = tx.send(Some(SocketAddrV4::new(external_ip, port)));
    let mut renew_at = Instant::now() + Duration::from_secs(LEASE_SECS as u64 / 2);
    loop {
        tokio::select! {
            done = &mut *stopped => {
                let _ = tokio::time::timeout(RELEASE, gateway.remove_port(p, port)).await;
                let _ = tx.send(None);
                if let Ok(done) = done {
                    let _ = done.send(());
                }
                return Held::Stopped;
            }
            _ = tokio::time::sleep(CHECK) => {}
            _ = nudge.notified() => {}
        }
        // Renew at half the lease, else just confirm. Either way a gateway that no longer holds
        // it is asked once more on the same port; one that still won't is searched for again.
        let renew = Instant::now() >= renew_at;
        let held = (!renew && upnp_holds(&gateway, p, port, local).await)
            || (gateway.add_port(p, port, local, LEASE_SECS, DESCRIPTION).await.is_ok() && upnp_holds(&gateway, p, port, local).await);
        if renew {
            renew_at = Instant::now() + Duration::from_secs(LEASE_SECS as u64 / 2);
        }
        if !held {
            tracing::warn!("the gateway no longer holds {proto:?} {port}: asking again");
            let _ = tx.send(None);
            return Held::Lost(port);
        }
        let _ = tx.send(Some(SocketAddrV4::new(external_ip, port)));
    }
}

/// No UPnP gateway: NAT-PMP or PCP through `portmapper`, kept alive (it renews), deactivated on
/// stop (it releases).
async fn pmp(proto: Proto, local_port: u16, tx: watch::Sender<Option<SocketAddrV4>>, stopped: oneshot::Receiver<oneshot::Sender<()>>, nudge: Arc<tokio::sync::Notify>) {
    let Some(port) = NonZeroU16::new(local_port) else { return };
    let protocol = pmp_protocol(proto);
    let client = portmapper::Client::new(portmapper::Config { enable_upnp: false, protocol, ..portmapper::Config::default() });
    client.update_local_port(port);
    client.procure_mapping();
    let mut rx = client.watch_external_address();
    let forward = async {
        let mut current: Option<SocketAddrV4> = None;
        loop {
            // Only a mapping a second request confirms is published, again at every half lease.
            let now = *rx.borrow();
            let held = match now {
                Some(a) if pmp_holds(protocol, port, a).await => Some(a),
                Some(a) => {
                    tracing::warn!("a NAT-PMP/PCP mapping {a} that a second request does not confirm: not advertised");
                    None
                }
                None => None,
            };
            if held != current {
                if held.is_some() {
                    said(Gateway::Mapped);
                }
                let _ = tx.send(held);
                current = held;
            }
            // A mapping the gateway lost (it restarted) is asked for again at once.
            if now.is_some() && held.is_none() {
                client.procure_mapping();
            }
            tokio::select! {
                r = rx.changed() => if r.is_err() { std::future::pending::<()>().await },
                _ = tokio::time::sleep(CHECK) => {}
                _ = nudge.notified() => {}
            }
        }
    };
    let done = tokio::select! {
        d = stopped => d.ok(),
        _ = forward => None,
    };
    client.deactivate();
    // The service releases on its own task: give it the moment it needs before the client drops.
    let mut rx = client.watch_external_address();
    let _ = tokio::time::timeout(RELEASE, async {
        while rx.borrow().is_some() {
            if rx.changed().await.is_err() {
                break;
            }
        }
    })
    .await;
    let _ = tx.send(None);
    if let Some(done) = done {
        let _ = done.send(());
    }
}

/// GetSpecificPortMappingEntry: does the gateway hold `external` for `p`, pointing at `local`?
/// (igd-next sends no such request; it goes the way its own do.)
async fn upnp_holds(gateway: &igd_next::aio::Gateway<aigd::Tokio>, p: PortMappingProtocol, external: u16, local: SocketAddr) -> bool {
    use igd_next::aio::Provider;
    let header = r#""urn:schemas-upnp-org:service:WANIPConnection:1#GetSpecificPortMappingEntry""#;
    let body = format!(
        r#"<?xml version="1.0"?><s:Envelope s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/" xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:GetSpecificPortMappingEntry xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1"><NewRemoteHost></NewRemoteHost><NewExternalPort>{external}</NewExternalPort><NewProtocol>{p}</NewProtocol></u:GetSpecificPortMappingEntry></s:Body></s:Envelope>"#
    );
    let Ok(Ok(text)) = tokio::time::timeout(CONFIRM, aigd::Tokio::send_async(&gateway.to_string(), header, &body)).await else { return false };
    let field = |name: &str| text.split(&format!("<{name}>")).nth(1).and_then(|r| r.split('<').next()).map(|v| v.trim().to_owned());
    text.contains("GetSpecificPortMappingEntryResponse")
        && field("NewInternalPort").as_deref() == Some(local.port().to_string().as_str())
        && field("NewInternalClient").as_deref() == Some(local.ip().to_string().as_str())
}

/// NAT-PMP and PCP return the mapping a host already holds for a local port: a second, separate
/// request must come back with the same external port. The second client is dropped without
/// deactivating, so it deletes nothing. (A strict PCP server may refuse the second client's nonce:
/// such a mapping then stays unconfirmed, and unadvertised, rather than advertised unproven.)
async fn pmp_holds(protocol: portmapper::Protocol, local_port: NonZeroU16, external: SocketAddrV4) -> bool {
    let second = portmapper::Client::new(portmapper::Config { enable_upnp: false, protocol, ..portmapper::Config::default() });
    second.update_local_port(local_port);
    second.procure_mapping();
    let mut rx = second.watch_external_address();
    let got = tokio::time::timeout(CONFIRM, async {
        loop {
            if let Some(a) = *rx.borrow() {
                return Some(a);
            }
            if rx.changed().await.is_err() {
                return None;
            }
        }
    })
    .await
    .ok()
    .flatten();
    drop(second);
    got.is_some_and(|a| a.port() == external.port())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// A gateway whose control URL answers every request with `status` and `body`.
    async fn gateway(status: &'static str, body: String) -> igd_next::aio::Gateway<aigd::Tokio> {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            while let Ok((mut s, _)) = listener.accept().await {
                let body = body.clone();
                tokio::spawn(async move {
                    let mut req = Vec::new();
                    let mut buf = [0u8; 4096];
                    while !String::from_utf8_lossy(&req).contains("</s:Envelope>") {
                        match s.read(&mut buf).await {
                            Ok(0) | Err(_) => return,
                            Ok(n) => req.extend_from_slice(&buf[..n]),
                        }
                    }
                    let reply = format!("HTTP/1.1 {status}\r\nContent-Type: text/xml\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
                    let _ = s.write_all(reply.as_bytes()).await;
                });
            }
        });
        igd_next::aio::Gateway { addr, root_url: "/".into(), control_url: "/ctl".into(), control_schema_url: "/scpd".into(), control_schema: Default::default(), provider: aigd::Tokio }
    }

    fn entry(client: &str, port: u16) -> String {
        format!(
            r#"<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:GetSpecificPortMappingEntryResponse xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1"><NewInternalPort>{port}</NewInternalPort><NewInternalClient>{client}</NewInternalClient><NewEnabled>1</NewEnabled><NewPortMappingDescription>peer</NewPortMappingDescription><NewLeaseDuration>3600</NewLeaseDuration></u:GetSpecificPortMappingEntryResponse></s:Body></s:Envelope>"#
        )
    }

    /// A link waits for the first answer, and no longer than `FIRST`: a mapping, or no gateway to
    /// ask, settles it at once.
    #[tokio::test]
    async fn the_first_answer_settles_a_mapping() {
        let (tx, external) = watch::channel(None);
        let m = |started, alone: bool| Mapping { external: external.clone(), stop: None, started, alone: Arc::new(AtomicBool::new(alone)), nudge: Default::default() };
        assert!(!m(Instant::now(), false).settled(), "asked a moment ago, no answer yet");
        assert!(m(Instant::now(), true).settled(), "no gateway here");
        assert!(m(Instant::now() - FIRST, false).settled(), "waited long enough");
        tx.send(Some("203.0.113.1:4101".parse().unwrap())).unwrap();
        assert!(m(Instant::now(), false).settled(), "mapped");
    }

    /// The home router after an outage said yes to AddPortMapping and held nothing: a mapping is
    /// one GetSpecificPortMappingEntry finds, for this address and port, and nothing else.
    #[tokio::test]
    async fn a_mapping_is_one_the_gateway_holds() {
        let local: SocketAddr = "192.168.1.91:4191".parse().unwrap();
        let holds = gateway("200 OK", entry("192.168.1.91", 4191)).await;
        assert!(upnp_holds(&holds, PortMappingProtocol::TCP, 61000, local).await);
        let fault = r#"<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>714</errorCode><errorDescription>NoSuchEntryInArray</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>"#;
        let nothing = gateway("500 Internal Server Error", fault.to_owned()).await;
        assert!(!upnp_holds(&nothing, PortMappingProtocol::TCP, 61000, local).await, "says yes, stores nothing");
        let someone_else = gateway("200 OK", entry("192.168.1.30", 4191)).await;
        assert!(!upnp_holds(&someone_else, PortMappingProtocol::TCP, 61000, local).await, "held, but for another host");
    }
}
