#!/usr/bin/env bash
# Builds the app's Xray core (xray/: Xray-core and a small Android API around it) with gomobile
# into android/app/libs/xray.aar, for every Android ABI. Needs the Android SDK and NDK; Go is
# the version in xray/go.mod (Xray-core's), and gomobile the one pinned there too.
set -euo pipefail
cd "$(dirname "$0")/../xray"

export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:?Set ANDROID_HOME to the Android SDK}}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$(ls -d "$ANDROID_HOME"/ndk/* | sort -V | tail -1)}"
OUT=../android/app/libs/xray.aar

# gomobile and gobind at go.mod's version, in a local bin directory; gomobile also runs javac
# (JAVA_HOME's, when set).
export GOBIN="$PWD/.bin"
export PATH="$GOBIN${JAVA_HOME:+:$JAVA_HOME/bin}:$PATH"
go install golang.org/x/mobile/cmd/gomobile golang.org/x/mobile/cmd/gobind
gomobile init

mkdir -p "$(dirname "$OUT")"
# -checklinkname=0: a dependency (wlynxg/anet) links into net internals, as in Psiphon's build.
gomobile bind -target=android -androidapi 24 -trimpath -ldflags "-s -w -buildid= -checklinkname=0" -o "$OUT" .
rm -f "${OUT%.aar}-sources.jar"
go version
ls -la "$OUT"
