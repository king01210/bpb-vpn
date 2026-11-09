#!/usr/bin/env bash
# Fetches Xray's routing data, geoip.dat and geosite.dat (Iran-focused rules), from the latest
# Chocolate4U/Iran-v2ray-rules release into the app's assets.
set -euo pipefail
cd "$(dirname "$0")"

BASE=https://github.com/Chocolate4U/Iran-v2ray-rules/releases/latest/download
ASSETS=../android/app/src/main/assets

mkdir -p "$ASSETS"
for f in geoip.dat geosite.dat; do
  curl -fsSL --retry 3 -o "$ASSETS/$f" "$BASE/$f"
done
ls -la "$ASSETS"/geoip.dat "$ASSETS"/geosite.dat
