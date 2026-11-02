//! `peer`: the network layer under baud, on iroh with no servers. See DESIGN.md for the rules and
//! the reasoning, SPEC.md for the API. Modules are one per noun.

pub mod blobs;
pub mod card;
pub mod catalog;
pub mod finding;
pub mod helper;
pub mod identity;
pub mod introduce;
pub mod link;
pub mod policy;
pub mod portmap;
pub mod probe;
pub mod record;
pub mod store;
pub mod sync;
pub mod trace;
pub mod transport;

mod api;
pub use api::*;
pub use iroh::TransportAddr;

use std::fmt;

/// Every fallible call returns one of these. Flat, so bindings map it to one enum.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum Error {
    #[error("not found")]
    NotFound,
    #[error("bad key")]
    BadKey,
    #[error("bad signature")]
    BadSignature,
    #[error("encoding")]
    Encoding,
    #[error("expired")]
    Expired,
    #[error("already used")]
    Used,
    #[error("not in their book")]
    NotInTheirBook,
    #[error("unreachable")]
    Unreachable,
    #[error("policy refused {0:?} over {1:?}")]
    PolicyRefused(policy::Class, Path),
    #[error("budget exceeded")]
    Budget,
    #[error("keychain: {0}")]
    Keychain(String),
    #[error("store: {0}")]
    Store(String),
    #[error("net: {0}")]
    Net(String),
    #[error("not implemented in this cut: {0}")]
    Unimplemented(&'static str),
}

pub type Result<T> = std::result::Result<T, Error>;

impl From<rusqlite::Error> for Error {
    fn from(e: rusqlite::Error) -> Self {
        Error::Store(e.to_string())
    }
}
impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Net(e.to_string())
    }
}

/// How a connection reaches a device, in words the UI can show.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum Path {
    /// A hole-punched or LAN path. `vpn` when the selected address is on a VPN interface
    /// (Tailscale's `100.64.0.0/10` or `fd7a:115c:a1e0::/48`).
    Direct { vpn: bool },
    /// Forwarded by the embedded relay of this helper device.
    Relay(identity::DeviceId),
    /// Found by mDNS on the LAN.
    Nearby,
    /// Known, not connected: waiting for either side to come within reach.
    Waiting,
    /// No record, or every address stale and no helper.
    Unreachable,
}

impl fmt::Display for Path {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Path::Direct { vpn: false } => f.write_str("direct"),
            Path::Direct { vpn: true } => f.write_str("direct, over your VPN"),
            Path::Relay(d) => write!(f, "relayed by {}", d.short()),
            Path::Nearby => f.write_str("nearby"),
            Path::Waiting => f.write_str("waiting"),
            Path::Unreachable => f.write_str("unreachable"),
        }
    }
}

pub fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
