#!/bin/bash
# libbaud_ffi.so for Android phones and the Apple-silicon emulator (arm64-v8a), into the app's
# jniLibs, and the Kotlin bindings next to it. Release: the phone runs this one.
#   scripts/build-android.sh [jniLibs dir]   (default ../apps/android/app/src/main/jniLibs)
set -euo pipefail
cd "$(dirname "$0")/.."
# rustup's toolchain, which has the Android target (a Homebrew rustc earlier on PATH has not).
export PATH="$HOME/.cargo/bin:$PATH"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/27.2.12479018}"
out="${1:-../apps/android/app/src/main/jniLibs}"
# minSdk 26, as the app's build.gradle.kts says.
cargo ndk -t arm64-v8a -P 26 -o "$out" build -p baud-ffi --release
scripts/bindings.sh >/dev/null
ls -la "$out/arm64-v8a/libbaud_ffi.so"
