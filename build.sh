#!/bin/bash
# Builds the Duo Mac helper into build/ and (first time only) the launcher app.
#   ./build.sh          build the helper
#   ./build.sh --app    also rebuild /Applications/Duo Mac.app (you'll need to re-allow permissions)
set -euo pipefail
cd "$(dirname "$0")"

echo "▸ Building helper…"
mkdir -p build
if ! swift build -c release --package-path helper > build/swift-build.log 2>&1; then grep -E "error" build/swift-build.log; echo "✗ Build failed"; exit 1; fi
BIN="$(swift build -c release --package-path helper --show-bin-path)/NanoHelper"
[ -x "$BIN" ] || { echo "Build failed"; exit 1; }
# The real binaries live in hidden .bin folders behind symlinks: Spotlight indexes neither, so searching
# "Duo Mac" finds the app and not a bare executable (which opens in Terminal, without the app's permissions).
mkdir -p build/.bin
rm -f "build/Duo Mac"
cp "$BIN" "build/.bin/Duo Mac"
xattr -c "build/.bin/Duo Mac" 2>/dev/null || true
codesign --force --sign - "build/.bin/Duo Mac"
ln -s ".bin/Duo Mac" "build/Duo Mac"

if [ ! -f web/icon-mac.png ] || [ ! -d build/AppIcon.iconset ]; then
  echo "▸ Drawing icons…"
  swift tools/make-icons.swift "$PWD"
fi

# Install the helper + web app outside ~/Documents: macOS asks for permission before an app
# may read files in Documents, and would block the helper on that prompt.
INSTALL="$HOME/Library/Application Support/Duo Mac"
# Renamed from MacBook Nano: keep its settings and paired devices.
OLD="$HOME/Library/Application Support/MacBook Nano"
if [ -d "$OLD" ] && [ ! -d "$INSTALL" ]; then
  mv "$OLD" "$INSTALL"
  rm -f "$INSTALL/MacBook Nano"
fi
echo "▸ Installing to $INSTALL"
mkdir -p "$INSTALL/.bin"
cp "build/.bin/Duo Mac" "$INSTALL/.bin/Duo Mac.new"
mv -f "$INSTALL/.bin/Duo Mac.new" "$INSTALL/.bin/Duo Mac"
[ -L "$INSTALL/Duo Mac" ] || { rm -f "$INSTALL/Duo Mac"; ln -s ".bin/Duo Mac" "$INSTALL/Duo Mac"; }
rsync -a --delete web/ "$INSTALL/web/"
# The Duo Mac Microphone driver: installed into the system by Duo Mac itself (Settings › General),
# which asks for an administrator password.
./tools/make-driver.sh >/dev/null
rsync -a --delete build/DuoMacMicrophone.driver/ "$INSTALL/DuoMacMicrophone.driver/"

APP="/Applications/Duo Mac.app"
# Without admin rights /Applications isn't writable: use ~/Applications (Spotlight lists apps there too).
if [ ! -d "$APP" ] && [ ! -w /Applications ]; then
  APP="$HOME/Applications/Duo Mac.app"
  mkdir -p "$HOME/Applications"
fi
export DUO_MAC_APP="$APP"
# It used to be built in this folder: move it (same signature, so permissions stay).
if [ -d "Duo Mac.app" ] && [ ! -d "$APP" ]; then
  mv "Duo Mac.app" "$APP"
fi
if [ ! -d "$APP" ] || [ "${1:-}" = "--app" ]; then
  ./tools/make-app.sh
fi
echo "✓ Done. Open Duo Mac from Applications (or Spotlight)."
