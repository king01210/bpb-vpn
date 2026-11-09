#!/usr/bin/env bash
# Fetches Tor Project's official Android expert bundles and installs, per ABI:
#   tor      → android/app/src/main/jniLibs/<abi>/libtor.so
#   lyrebird → android/app/src/main/jniLibs/<abi>/liblyrebird.so   (obfs4, meek, webtunnel, snowflake)
# plus, once: Tor's IPv4 and IPv6 GeoIP files (for ExitNodes by country) and pt_config.json
# (the built-in bridges) as app assets. Both binaries are executables despite the .so names:
# Android only installs native libraries, and runs them from nativeLibraryDir.
# Hashes are from https://dist.torproject.org/torbrowser/$VERSION/sha256sums-signed-build.txt
# Paths are relative to this script (scripts/), so it runs from anywhere.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=16.0
BASE="https://dist.torproject.org/torbrowser/$VERSION"
JNI=../android/app/src/main/jniLibs
ASSETS=../android/app/src/main/assets

declare -A ABI=([aarch64]=arm64-v8a [armv7]=armeabi-v7a [x86_64]=x86_64)
declare -A SHA=(
  [aarch64]=bf8f4c63652fd7daa62288713c7fa512f244a5b972808f6251450e5fdfca9120
  [armv7]=13befa352b64c32ba460b63066179bb1c9eaf6c3ea7057ae860dcdd22b8acf7b
  [x86_64]=ab3152ba164bcd49e50175086c62e40ffa2bf9002a4f6473f77111bd88b0462b
)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for arch in aarch64 armv7 x86_64; do
  file="tor-expert-bundle-android-$arch-$VERSION.tar.gz"
  echo "fetching $file"
  curl -fsSL -o "$TMP/$file" "$BASE/$file"
  echo "${SHA[$arch]}  $TMP/$file" | sha256sum -c --quiet -
  mkdir -p "$TMP/$arch" "$JNI/${ABI[$arch]}"
  tar -xzf "$TMP/$file" -C "$TMP/$arch"
  cp "$TMP/$arch/tor/libTor.so" "$JNI/${ABI[$arch]}/libtor.so"
  cp "$TMP/$arch/tor/pluggable_transports/lyrebird" "$JNI/${ABI[$arch]}/liblyrebird.so"
done

cp "$TMP/aarch64/data/geoip" "$ASSETS/tor_geoip"
cp "$TMP/aarch64/data/geoip6" "$ASSETS/tor_geoip6"
cp "$TMP/aarch64/tor/pluggable_transports/pt_config.json" "$ASSETS/tor_pt_config.json"
ls -la "$JNI"/*/libtor.so "$JNI"/*/liblyrebird.so "$ASSETS"/tor_*
