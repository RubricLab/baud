//! baud-core: baud on peer. `LocalCore.swift`, `Carry.swift`, `Transport.swift`, `Files.swift`
//! and the apps' `Baud.swift` glue, in Rust, wire-compatible with them: an Android phone and
//! the iPhone and Mac apps exchange the same frames.

pub mod error;
pub mod ids;
pub mod json;
pub mod link;
pub mod sentences;
pub mod store;
pub mod types;
pub mod wire;

mod carry;
mod core;
mod files;
mod net;
mod places;
mod wake;

pub use crate::core::Core;
pub use error::{Error, Result};
pub use files::{file_hash, mime_of, pixel_size};
pub use net::ALPN;
pub use wake::{RELAY as WAKE_RELAY, WakeKind, relay_get};

pub fn version() -> String {
    format!("baud-core {} · peer {}", env!("CARGO_PKG_VERSION"), peer::version())
}
