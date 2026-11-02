#!/bin/bash
# The generated Kotlin on the JVM against the host library (bindings/smoke/Smoke.kt): proves the
# bindings compile and call through (suspend calls, Keychain, Listener, errors) without a phone.
# Uses Android Studio's bundled kotlinc and JBR, and coroutines from Gradle's cache.
set -euo pipefail
cd "$(dirname "$0")/.."
AS="/Applications/Android Studio.app/Contents"
export JAVA_HOME="${JAVA_HOME:-$AS/jbr/Contents/Home}"
export PATH="$JAVA_HOME/bin:$PATH"
# Desktop JNA 5.15 (the AAR has no macOS natives): JNA_JAR, else from Gradle's or Maven's cache.
JNA="${JNA_JAR:-$(find ~/.gradle/caches/modules-2 ~/.m2 -name 'jna-5.15.0.jar' 2>/dev/null | head -1)}"
[ -f "$JNA" ] || { echo "set JNA_JAR to jna-5.15.0.jar (repo1.maven.org/maven2/net/java/dev/jna/jna/5.15.0/)"; exit 1; }
CO=$(find ~/.gradle/caches/modules-2 -name 'kotlinx-coroutines-core-jvm-1.6.4.jar' | head -1)
KLIB="$AS/plugins/Kotlin/kotlinc/lib"
out="${TMPDIR:-/tmp}/baud-kotlin-smoke"
cargo build -q -p baud-ffi
rm -rf "$out" && mkdir -p "$out"
bash "$AS/plugins/Kotlin/kotlinc/bin/kotlinc" -nowarn -cp "$JNA:$CO" -d "$out/classes" bindings/kotlin/sh/rubric/baud/ffi/baud.kt bindings/smoke/Smoke.kt
java -Djna.library.path="$PWD/target/debug" -cp "$out/classes:$JNA:$CO:$KLIB/kotlin-stdlib.jar" SmokeKt "$out/data"
