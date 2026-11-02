//! The release gate. A node built by this crate has no host to talk to but its peers: no relay
//! URL from a default, no DNS, no pkarr. And the source never names one.

use std::sync::Arc;

use peer::identity::MemoryKeychain;
use peer::{Config, Peer};

#[tokio::test]
async fn a_fresh_node_knows_no_non_peer_host() {
    let dir = tempfile::tempdir().unwrap();
    let peer = Peer::open(dir.path().to_path_buf(), Arc::new(MemoryKeychain::default()), Config::new("gate", "ana", "test")).await.unwrap();
    let hosts = peer.transport().hosts();
    assert!(hosts.is_empty(), "configured non-peer hosts: {hosts:?}");
    assert_eq!(peer.addr().relay_urls().count(), 0, "a home relay with no helper in the book");
    peer.close().await;
}

#[test]
fn the_source_never_names_a_public_relay_or_discovery() {
    let forbidden = ["presets::N0", "RelayMode::Default", "RelayMode::Staging", "iroh.link", "n0.computer", "pkarr", "DnsAddressLookup", "iroh_dns"];
    let src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut checked = 0;
    for entry in std::fs::read_dir(&src).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_none_or(|e| e != "rs") {
            continue;
        }
        // Code only: comments may say what is disabled; code may never enable it.
        let text: String = std::fs::read_to_string(&path).unwrap().lines().map(|l| l.split("//").next().unwrap_or("")).collect::<Vec<_>>().join("\n");
        for f in forbidden {
            assert!(!text.contains(f), "{} mentions {f}", path.display());
        }
        checked += 1;
    }
    assert!(checked >= 10, "expected every module to be checked, saw {checked}");
    // The workspace never enables a feature that could add them either.
    let manifest = std::fs::read_to_string(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../Cargo.toml")).unwrap();
    assert!(manifest.contains("default-features = false"), "iroh must be built without its defaults");
    assert!(!manifest.contains("\"discovery"), "no iroh discovery feature");
}
