//! Reachability. On every network change: ask up to four devices we hold a direct path to what
//! address they see us at, own devices first, then the host of each relay our connections ride
//! (on its Bind-only ALPN, which answers only the devices its relay admits), and try UPnP,
//! NAT-PMP and PCP. Each address family
//! on its own terms. IPv4: a mapping, or one port across responders, is `Yes`; differing ports
//! (a NAT that picks a new port per destination) is `No`; fewer than two distinct responders is
//! `Unknown`, advertised as false, inbound still attempted. IPv6: seen untranslated, as one of
//! this device's own addresses, is `Yes`: nothing rewrites it, so a punch knows both ends exactly
//! (a firewall may stand there; simultaneous sends cross it). The observed public IPv4 address
//! feeds `Endpoint::add_external_addr`, which is what n0's QAD did. No second socket, no
//! unauthenticated UDP responder.
//!
//! A mapping is the gateway's word, and a gateway can grant one and forward nothing (Dexter's,
//! after losing its WAN, answered every request "yes"). So a responder that sees us across the
//! internet at the mapping's own address is asked to dial back to it (`dial_back`), and a mapping
//! that answered nobody is not advertised. With nobody to ask, the gateway's word stands.

use std::collections::BTreeSet;
use std::net::SocketAddr;
use std::time::Duration;

use iroh::endpoint::Connection;
use serde::{Deserialize, Serialize};

use crate::identity::DeviceId;
use crate::record::is_global;
use crate::transport::{self, Msg, ask};
use crate::{Error, Result};

pub const RESPONDERS: usize = 4;
pub const MIN_RESPONDERS: usize = 2;
const BIND_TIMEOUT: Duration = Duration::from_secs(3);
const MAPPING_TIMEOUT: Duration = Duration::from_secs(5);
/// Responders asked to dial back to the mappings, and how long each dial may take.
pub const CHECKERS: usize = 2;
const DIAL_BACK_TIMEOUT: Duration = Duration::from_secs(3);
/// A dial back and the throwaway endpoint it opens.
const CHECK_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Reachable {
    Yes,
    No,
    Unknown,
}

impl Reachable {
    /// What goes in the record: unknown is advertised as false.
    pub fn advertised(self) -> bool {
        self == Reachable::Yes
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Observation {
    pub responder: DeviceId,
    pub observed: SocketAddr,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Outcome {
    pub reachable: Reachable,
    pub observations: Vec<Observation>,
    /// A port mapping the gateway granted, if any.
    pub mapping: Option<SocketAddr>,
    /// The address to advertise, if the probe found one.
    pub public: Option<SocketAddr>,
    /// Whether the UDP mapping and the relay's TCP one answered from outside (`verdict`).
    pub udp_check: Option<bool>,
    pub tcp_check: Option<bool>,
}

/// What the dial-backs say of one mapping: reached by any is `Some(true)`, by none of those who
/// could try is `Some(false)`, nobody could try is `None` (the gateway's word stands).
pub fn verdict(answers: &[Option<bool>]) -> Option<bool> {
    if answers.contains(&Some(true)) {
        Some(true)
    } else if answers.contains(&Some(false)) {
        Some(false)
    } else {
        None
    }
}

/// The decision, from observations alone. Pure, so the table below is the whole truth. `local`
/// are this endpoint's own addresses.
pub fn classify(observations: &[Observation], mapping: Option<SocketAddr>, local: &[SocketAddr]) -> Reachable {
    if mapping.is_some() || open_v6(observations, local) {
        return Reachable::Yes;
    }
    // Only a responder across the internet sees the NAT's mapping: a LAN peer sees the local
    // port and a VPN peer sees the VPN's, and neither says anything about reachability.
    let v4 = public_v4(observations);
    let distinct: BTreeSet<DeviceId> = v4.iter().map(|o| o.responder).collect();
    if distinct.len() < MIN_RESPONDERS {
        return Reachable::Unknown;
    }
    // Ports, not addresses: a node with several interfaces is seen at several IPs on one port.
    let ports: BTreeSet<u16> = v4.iter().map(|o| o.observed.port()).collect();
    if ports.len() == 1 { Reachable::Yes } else { Reachable::No }
}

/// Seen across the internet at one of my own IPv6 addresses: nothing translates it.
fn open_v6(observations: &[Observation], local: &[SocketAddr]) -> bool {
    observations.iter().any(|o| o.observed.is_ipv6() && is_global(&o.observed.ip()) && local.iter().any(|l| l.ip() == o.observed.ip()))
}

/// What responders across the internet saw over IPv4: the only family a NAT rewrites.
fn public_v4(observations: &[Observation]) -> Vec<&Observation> {
    observations.iter().filter(|o| o.observed.is_ipv4() && is_global(&o.observed.ip())).collect()
}

/// The IPv4 address to advertise: the most common observed one that is not a local interface's
/// (those iroh already knows), when the ports agree. IPv6 is never translated, so iroh has it.
pub fn public_of(observations: &[Observation], local: &[SocketAddr]) -> Option<SocketAddr> {
    let v4 = public_v4(observations);
    let ports: BTreeSet<u16> = v4.iter().map(|o| o.observed.port()).collect();
    if ports.len() != 1 {
        return None;
    }
    let mut counts: std::collections::BTreeMap<SocketAddr, usize> = Default::default();
    for o in v4.into_iter().filter(|o| !local.contains(&o.observed)) {
        *counts.entry(o.observed).or_default() += 1;
    }
    counts.into_iter().max_by_key(|(_, n)| *n).map(|(a, _)| a)
}

/// One binding request over an authenticated connection. `None` means the far side only has a
/// relayed path to us, which is itself an answer: it cannot serve as a responder.
pub async fn bind(conn: &Connection) -> Result<Option<SocketAddr>> {
    match tokio::time::timeout(BIND_TIMEOUT, ask(conn, &Msg::Bind)).await {
        Ok(Ok(Msg::Bound(addr))) => Ok(addr),
        Ok(Ok(_)) => Err(Error::Encoding),
        Ok(Err(e)) => Err(e),
        Err(_) => Err(Error::Unreachable),
    }
}

/// Answer a `Check` on `conn`: dial back to the asker's mapped ports at the address its direct
/// path to me comes from, never anywhere else, from a throwaway endpoint (mine would send down
/// the path we already share). A handshake with its key through the UDP port, or a relay
/// answering on the TCP one, is the mapping forwarding. Only across the internet: a LAN or VPN
/// path says nothing of its router, and over a relayed one I would show the asker where I am.
pub async fn dial_back(conn: &Connection, udp: Option<u16>, tcp: Option<u16>) -> (Option<bool>, Option<bool>) {
    let direct = matches!(transport::path_of(conn, |_| None).0, crate::Path::Direct { vpn: false });
    let Some(ip) = transport::observed(conn).map(|a| a.ip()).filter(|ip| direct && ip.is_ipv4() && is_global(ip)) else { return (None, None) };
    let Ok(ep) = transport::throwaway().await else { return (None, None) };
    let id = conn.remote_id();
    let tcp_url = tcp.and_then(|p| format!("http://{}", SocketAddr::new(ip, p)).parse::<iroh::RelayUrl>().ok());
    let checks = tokio::join!(
        async {
            match udp {
                Some(p) => Some(transport::handshakes(&ep, id, SocketAddr::new(ip, p), DIAL_BACK_TIMEOUT).await),
                None => None,
            }
        },
        async {
            match tcp_url {
                Some(u) => Some(transport::relay_answers(&ep, u, DIAL_BACK_TIMEOUT).await),
                None => None,
            }
        }
    );
    // The answer goes now: closing waits on the connections it made.
    tokio::spawn(async move { ep.close().await });
    checks
}

/// Ask `conn` to dial back to my mappings.
async fn check(conn: &Connection, udp: Option<SocketAddr>, tcp: Option<SocketAddr>) -> (Option<bool>, Option<bool>) {
    let msg = Msg::Check { udp: udp.map(|a| a.port()), tcp: tcp.map(|a| a.port()) };
    match tokio::time::timeout(CHECK_TIMEOUT, ask(conn, &msg)).await {
        Ok(Ok(Msg::Checked { udp, tcp })) => (udp, tcp),
        _ => (None, None),
    }
}

/// How long a relay waits for its TCP mapping before it is not offered.
pub const MAPPING_WAIT: Duration = MAPPING_TIMEOUT;

/// The whole probe. `conns` are in preference order (own devices first); the first
/// `RESPONDERS` with a direct path are asked, in parallel. `mapping` is the node's UDP mapping,
/// if it holds one (`peer::portmap`), `relay` its relay's TCP one; `doubted` a UDP mapping an
/// earlier check did not get through, which counts again only once one does; `local` are this
/// endpoint's own direct addresses, never advertised as public.
pub async fn run(conns: &[(DeviceId, Connection)], mapping: Option<SocketAddr>, relay: Option<SocketAddr>, doubted: Option<SocketAddr>, local: &[SocketAddr]) -> Outcome {
    let mut asks = Vec::new();
    // A direct path, not over a VPN: a relayed one has no answer and would take a responder's place.
    for (device, conn) in conns.iter().filter(|(_, c)| transport::observed(c).is_some_and(|a| !crate::record::is_vpn(&a.ip()))).take(RESPONDERS) {
        let (device, conn) = (*device, conn.clone());
        asks.push(tokio::spawn(async move { (device, bind(&conn).await) }));
    }
    let mut observations = Vec::new();
    for a in asks {
        if let Ok((responder, Ok(Some(observed)))) = a.await {
            observations.push(Observation { responder, observed });
        }
    }
    // The mappings, dialed back by responders that see me at their address across the internet.
    let at = mapping.or(relay).map(|a| a.ip());
    let checks: Vec<_> = conns
        .iter()
        .filter(|(d, _)| at.is_some() && observations.iter().any(|o| o.responder == *d && Some(o.observed.ip()) == at))
        .take(CHECKERS)
        .map(|(_, c)| {
            let c = c.clone();
            tokio::spawn(async move { check(&c, mapping, relay).await })
        })
        .collect();
    let (mut udp, mut tcp) = (Vec::new(), Vec::new());
    for c in checks {
        if let Ok((u, t)) = c.await {
            udp.push(u);
            tcp.push(t);
        }
    }
    let (udp_check, tcp_check) = (verdict(&udp), verdict(&tcp));
    let mapping = mapping.filter(|m| udp_check.unwrap_or(doubted != Some(*m)));
    let reachable = classify(&observations, mapping, local);
    let public = mapping.or_else(|| public_of(&observations, local));
    Outcome { reachable, observations, mapping, public, udp_check, tcp_check }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn obs(d: u8, addr: &str) -> Observation {
        Observation { responder: DeviceId([d; 32]), observed: addr.parse().unwrap() }
    }

    #[test]
    fn table() {
        assert_eq!(classify(&[], None, &[]), Reachable::Unknown);
        assert_eq!(classify(&[obs(1, "203.0.113.1:5000")], None, &[]), Reachable::Unknown);
        assert_eq!(classify(&[obs(1, "203.0.113.1:5000"), obs(1, "203.0.113.1:5000")], None, &[]), Reachable::Unknown, "one responder twice is one");
        assert_eq!(classify(&[obs(1, "203.0.113.1:5000"), obs(2, "203.0.113.1:5000")], None, &[]), Reachable::Yes);
        assert_eq!(classify(&[obs(1, "203.0.113.1:5000"), obs(2, "203.0.113.1:5001")], None, &[]), Reachable::No);
        assert_eq!(classify(&[obs(1, "203.0.113.1:5000"), obs(2, "203.0.113.1:5000"), obs(3, "203.0.113.1:5002")], None, &[]), Reachable::No);
        assert_eq!(classify(&[], Some("203.0.113.1:4101".parse().unwrap()), &[]), Reachable::Yes, "a mapping is enough");
        assert_eq!(classify(&[obs(1, "203.0.113.1:5000"), obs(2, "100.64.0.9:5000")], None, &[]), Reachable::Unknown, "a VPN responder does not count");
        assert_eq!(classify(&[obs(1, "198.51.100.7:5000"), obs(2, "203.0.113.1:5000")], None, &[]), Reachable::Yes, "two public responders, one port");
        assert_eq!(classify(&[obs(1, "127.0.0.1:5000"), obs(2, "10.0.0.2:5000")], None, &[]), Reachable::Unknown, "LAN peers say nothing about the NAT");
        assert_eq!(classify(&[obs(1, "203.0.113.1:36379"), obs(2, "192.168.1.30:4101"), obs(3, "198.51.100.7:36379")], None, &[]), Reachable::Yes, "a LAN peer never breaks a public verdict");
        let local = ["10.0.0.2:5000".parse().unwrap()];
        assert_eq!(public_of(&[obs(1, "203.0.113.1:5000"), obs(2, "10.0.0.2:5000"), obs(3, "203.0.113.1:5000")], &local), Some("203.0.113.1:5000".parse().unwrap()));
        assert_eq!(public_of(&[obs(1, "127.0.0.1:5000"), obs(2, "10.0.0.2:5000")], &local), None, "nothing public seen");
        // IPv6, on its own terms: untranslated is open, from one responder; it never muddies IPv4.
        let mine = ["[2001:db8::7]:4101".parse().unwrap(), "192.168.1.30:4101".parse().unwrap()];
        assert_eq!(classify(&[obs(1, "[2001:db8::7]:4101")], None, &mine), Reachable::Yes, "seen at my own IPv6 address");
        assert_eq!(classify(&[obs(1, "[2001:db8::99]:4101")], None, &mine), Reachable::Unknown, "a translated IPv6 address says nothing");
        assert_eq!(classify(&[obs(1, "203.0.113.1:5000"), obs(2, "[2001:db8::7]:4101")], None, &mine), Reachable::Yes, "IPv6 open beside a lone IPv4 answer");
        assert_eq!(classify(&[obs(1, "203.0.113.1:5000"), obs(2, "203.0.113.1:5000"), obs(3, "[2001:db8::99]:4101")], None, &mine), Reachable::Yes, "an IPv6 port never breaks an IPv4 verdict");
        assert_eq!(classify(&[obs(1, "203.0.113.1:5000"), obs(2, "203.0.113.1:5001"), obs(3, "[2001:db8::99]:4101")], None, &mine), Reachable::No, "a per-destination NAT stays no");
        assert_eq!(public_of(&[obs(1, "203.0.113.1:5000"), obs(2, "[2001:db8::7]:4101"), obs(3, "203.0.113.1:5000")], &mine), Some("203.0.113.1:5000".parse().unwrap()), "the public IPv4 address, IPv6 aside");
        assert!(!Reachable::Unknown.advertised());
        assert!(Reachable::Yes.advertised());
    }

    /// A gateway that maps and forwards nothing: one dial back that got through is enough, one
    /// that did not (and none that did) withdraws the mapping, and nobody to ask leaves it be.
    #[test]
    fn a_mapping_stands_on_what_answered() {
        assert_eq!(verdict(&[Some(false), Some(true)]), Some(true));
        assert_eq!(verdict(&[Some(false), None]), Some(false));
        assert_eq!(verdict(&[None, None]), None, "nobody across the internet to ask");
        assert_eq!(verdict(&[]), None);
    }
}
