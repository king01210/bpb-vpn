#!/usr/bin/env bash
# Builds the Psiphon exit binary (psiphon/) for every Android ABI into the app's jniLibs, as
# libpsiphon.so so Android installs it next to the app's native libraries (where it
# may be executed). Needs the Android NDK; Psiphon's TLS fork needs Go 1.26 (the
# toolchain line in go.mod), which `go` downloads itself.
set -euo pipefail
cd "$(dirname "$0")/../psiphon"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:?Set ANDROID_HOME to the Android SDK}}"
NDK="${ANDROID_NDK_HOME:-$(ls -d "$SDK"/ndk/* | sort -V | tail -1)}"
HOST=$(ls "$NDK/toolchains/llvm/prebuilt" | head -1)
BIN="$NDK/toolchains/llvm/prebuilt/$HOST/bin"
API=24
# Psiphon's TLS fork only works with the Go version it targets; go.mod's toolchain line
# alone doesn't downgrade a newer local Go, so force it.
export GOTOOLCHAIN=go1.26.9
OUT=../android/app/src/main/jniLibs
EXT=""; [[ "$HOST" == windows* ]] && EXT=".cmd"

# -checklinkname=0: a pion dependency (wlynxg/anet) links into net internals, as in
# Psiphon's own MobileLibrary/Android/make.bash.
build() { # abi goarch clang-target [goarm]
  mkdir -p "$OUT/$1"
  echo "building $1"
  CGO_ENABLED=1 GOOS=android GOARCH="$2" GOARM="${4:-}" CC="$BIN/$3$API-clang$EXT" \
    go build -trimpath -buildvcs=false -ldflags "-s -w -buildid= -checklinkname=0" -o "$OUT/$1/libpsiphon.so" .
}

build arm64-v8a arm64 aarch64-linux-android
build armeabi-v7a arm armv7a-linux-androideabi 7
build x86_64 amd64 x86_64-linux-android
go version
ls -la "$OUT"/*/libpsiphon.so
