#!/bin/bash
# Builds libtailscale (github.com/tailscale/libtailscale): Tailscale as a library, built into the
# iPhone app (ios/Tailscale/) so the app is its own device on your tailnet. Needs Go (it fetches the
# version libtailscale asks for). The source lives in ~/Library/Caches (its Makefile can't take a path
# with spaces, like this folder's).
#   tools/build-libtailscale.sh          iPhone (ios/Tailscale/libtailscale_ios.a)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
SRC="$HOME/Library/Caches/DuoMac/libtailscale"
if [ ! -d "$SRC" ]; then
  mkdir -p "$(dirname "$SRC")"
  git clone --depth 1 https://github.com/tailscale/libtailscale "$SRC"
fi
export GOTOOLCHAIN=auto
(cd "$SRC" && rm -f libtailscale_ios.a && make libtailscale_ios.a)
mkdir -p ios/Tailscale
cp "$SRC/libtailscale_ios.a" "$SRC/tailscale.h" "$ROOT/ios/Tailscale/"
echo "✓ ios/Tailscale/libtailscale_ios.a"
