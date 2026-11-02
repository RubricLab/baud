#!/bin/bash
# The signed release APK for a direct download: build/ship-android/baud-<version>.apk, its
# certificate checked against baud's release key, and its sha256 for releases.json.
#   scripts/ship-android.sh
# The key is ~/.android-keys/baud-release.jks (PKCS12, alias baud); its password stays in the login
# keychain and reaches Gradle only through this process's environment.
set -euo pipefail
cd "$(dirname "$0")/.."
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
EXPECT="0D:61:2A:2A:BE:22:ED:1F:FE:D6:74:74:CB:69:73:4E:06:72:60:AC:3D:29:06:A9:93:46:5C:38:36:83:8C:21"

VERSION=$(sed -n 's/^ *versionName = "\(.*\)"/\1/p' app/build.gradle.kts)
# The build number from the UTC clock, as iOS's: yyDDDHHmm (Android caps it at 2,100,000,000).
export BAUD_BUILD_NUMBER=$(date -u +%y%j%H%M)
BAUD_RELEASE_PASSWORD="$(security find-generic-password -a baud-android -s "baud android release key" -w)"
export BAUD_RELEASE_PASSWORD

./gradlew :app:assembleRelease --console=plain -q
unset BAUD_RELEASE_PASSWORD

OUT=build/ship-android
mkdir -p "$OUT"
APK="$OUT/baud-$VERSION.apk"
cp app/build/outputs/apk/release/app-release.apk "$APK"

SIGNER=$(ls -d "$ANDROID_HOME"/build-tools/* | sort -V | tail -1)/apksigner
CERT=$("$SIGNER" verify --print-certs "$APK" | sed -n 's/.*certificate SHA-256 digest: //p' | head -1 | tr 'a-f' 'A-F' | sed 's/../&:/g; s/:$//')
if [ "$CERT" != "$EXPECT" ]; then echo "signed with $CERT, not baud's release key" >&2; exit 1; fi

echo "baud $VERSION (build $BAUD_BUILD_NUMBER), signed with baud's release key"
echo "$(pwd)/$APK"
shasum -a 256 "$APK" | awk '{print "sha256 " $1}'
