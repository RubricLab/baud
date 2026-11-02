#!/bin/bash
# The Kotlin bindings from the built library's own metadata (uniffi library mode): bindings/kotlin.
# A host build is enough: the API is the same on every target.
set -euo pipefail
cd "$(dirname "$0")/.."
cargo build -p baud-ffi --features bindgen
lib=target/debug/libbaud_ffi.dylib
[ -f "$lib" ] || lib=target/debug/libbaud_ffi.so
rm -rf bindings/kotlin && mkdir -p bindings/kotlin
cargo run -q -p baud-ffi --features bindgen --bin uniffi-bindgen -- generate --library "$lib" --language kotlin --no-format --out-dir bindings/kotlin
find bindings/kotlin -name '*.kt'
