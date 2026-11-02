# peer

The network under baud: a Rust library that carries bytes between people's devices with no
server in the middle. Built on [iroh](https://github.com/n0-computer/iroh) with none of n0's
public servers: no relay map, no DNS, no discovery service.

- A device is an Ed25519 key, a person is another, and a signed **card** lists a person's devices.
- People meet by **link**: once, for an hour, everything after the `#`.
- Each device keeps an **address book** of signed records that go only to its mutuals.
- Devices connect **directly** over QUIC, with port mapping, reachability probes, and hole punches
  that a mutual's device coordinates.
- When they can't, a trusted **helper** (an own device, then a friend's) relays packets or carries
  sealed envelopes until the recipient is back.

[`../docs/protocol.md`](../docs/protocol.md) explains it end to end.
[`DESIGN.md`](DESIGN.md) has the rules and the reasoning, and [`SPEC.md`](SPEC.md) the API.

## Layout

| Folder | |
| --- | --- |
| `peer/` | The library. One module per noun: `identity`, `card`, `link`, `record`, `finding`, `probe`, `portmap`, `introduce`, `helper`, `policy`, `transport`, `store`. |
| `peer-uniffi/` | Bindings for Swift and Kotlin (UniFFI). |
| `swift/PeerKit/` | The Swift package the Apple apps use, made by `scripts/build-swift.sh`. |
| `peer-node/` | The library as a command-line node, for a computer that stays on. Also the lab's device and the bench. |
| `vendor/` | iroh and iroh-relay 1.3.0 with a few fixes of ours, each marked `peer:`. `Cargo.toml` lists them. |
| `lab/` | Real nodes behind emulated routers (home, UPnP, CGNAT, double NAT, IPv6-only, UDP blocked, lossy) in Docker. |
| `examples/` | The main journeys, step by step with `peer-node`. |

## Build and test

```sh
cargo test --workspace         # unit and in-process journey tests
scripts/build-swift.sh         # swift/PeerKit for iOS, the simulator and macOS
cargo build --release -p peer-node
target/release/peer-node --help
```

A release gate (`peer-node gate`, and `peer/tests/gate.rs` in process) checks that a fresh node
contacts no host but its peers.
