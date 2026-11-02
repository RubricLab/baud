#!/bin/sh
# Builds libpeer_uniffi.a for iOS, the iOS simulator and macOS, generates the Swift bindings,
# and assembles swift/PeerKit/peerFFI.xcframework. Run from the repo root.
set -eu
cd "$(dirname "$0")/.."
# Homebrew's cargo has no iOS targets; use a rustup toolchain that does.
export PATH="$HOME/.cargo/bin:$PATH"
if ! rustup target list --installed 2>/dev/null | grep -q aarch64-apple-ios; then
  for tc in "$HOME"/.rustup/toolchains/*; do
    if [ -d "$tc/lib/rustlib/aarch64-apple-ios" ]; then export RUSTUP_TOOLCHAIN="$(basename "$tc")"; break; fi
  done
fi
for t in aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin x86_64-apple-darwin; do
  rustup target list --installed | grep -q "^$t$" || rustup target add "$t"
done
# cc and rustc must agree on the deployment target, or sqlite's stack probes (___chkstk_darwin) fail to link.
export IPHONEOS_DEPLOYMENT_TARGET=17.0 MACOSX_DEPLOYMENT_TARGET=14.0
for t in aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin x86_64-apple-darwin; do
  cargo build --release -p peer-uniffi --target "$t"
done
# The macOS slice is universal, so apps can archive with generic/platform=macOS.
mkdir -p target/universal-apple-darwin/release
lipo -create target/aarch64-apple-darwin/release/libpeer_uniffi.a target/x86_64-apple-darwin/release/libpeer_uniffi.a -output target/universal-apple-darwin/release/libpeer_uniffi.a
out=target/uniffi-swift
rm -rf "$out" swift/PeerKit/peerFFI.xcframework
mkdir -p "$out/headers"
cargo run --release -p peer-uniffi --features bindgen --bin uniffi-bindgen-swift -- \
  --swift-sources --headers --modulemap --module-name peerFFI --modulemap-filename module.modulemap \
  target/aarch64-apple-darwin/release/libpeer_uniffi.a "$out"
mv "$out"/*.h "$out"/module.modulemap "$out/headers/"
mv "$out"/*.swift swift/PeerKit/Sources/PeerKit/PeerKit.swift
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libpeer_uniffi.a -headers "$out/headers" \
  -library target/aarch64-apple-ios-sim/release/libpeer_uniffi.a -headers "$out/headers" \
  -library target/universal-apple-darwin/release/libpeer_uniffi.a -headers "$out/headers" \
  -output swift/PeerKit/peerFFI.xcframework
du -sh swift/PeerKit/peerFFI.xcframework
