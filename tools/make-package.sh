#!/bin/bash
# Packs a ready-built Duo Mac into build/Duo Mac Installer.zip, for a Mac without Git or the
# Xcode tools: copy the zip over (AirDrop, USB stick), unzip it, run its installer.
# Apple silicon only, like the build itself.
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh >/dev/null

STAGE="build/package/Duo Mac Installer"
rm -rf build/package
mkdir -p "$STAGE/payload"
cp "build/.bin/Duo Mac" "$STAGE/payload/Duo Mac"
rsync -a web/ "$STAGE/payload/web/"
rsync -a build/DuoMacMicrophone.driver/ "$STAGE/payload/DuoMacMicrophone.driver/"
DUO_MAC_APP="$PWD/$STAGE/payload/Duo Mac.app" ./tools/make-app.sh >/dev/null

cat > "$STAGE/Install Duo Mac.command" <<'SH'
#!/bin/bash
# Installs Duo Mac from this folder. If double-clicking is blocked, open Terminal, type "bash "
# (with the space), drag this file into the window and press Return.
set -euo pipefail
cd "$(dirname "$0")"
[ "$(uname -m)" = arm64 ] || { echo "Duo Mac needs a Mac with Apple silicon."; exit 1; }
# Copied over AirDrop or downloaded, the files carry a quarantine mark that stops them opening.
xattr -cr payload 2>/dev/null || true

INSTALL="$HOME/Library/Application Support/Duo Mac"
echo "▸ Installing to $INSTALL"
mkdir -p "$INSTALL/.bin"
cp "payload/Duo Mac" "$INSTALL/.bin/Duo Mac.new"
mv -f "$INSTALL/.bin/Duo Mac.new" "$INSTALL/.bin/Duo Mac"
[ -L "$INSTALL/Duo Mac" ] || { rm -f "$INSTALL/Duo Mac"; ln -s ".bin/Duo Mac" "$INSTALL/Duo Mac"; }
rsync -a --delete payload/web/ "$INSTALL/web/"
rsync -a --delete payload/DuoMacMicrophone.driver/ "$INSTALL/DuoMacMicrophone.driver/"

APP="/Applications/Duo Mac.app"
[ -d "$APP" ] || [ -w /Applications ] || { APP="$HOME/Applications/Duo Mac.app"; mkdir -p "$HOME/Applications"; }
# An app that's already there keeps its permissions: only the helper and web app are updated.
[ -d "$APP" ] || ditto "payload/Duo Mac.app" "$APP"

if pgrep -x "Duo Mac" >/dev/null; then
  pkill -x "Duo Mac" || true
  sleep 2
fi
open -a "$APP"
echo "✓ Done. The Duo Mac setup guide opens on this Mac."
SH
chmod +x "$STAGE/Install Duo Mac.command"

rm -f "build/Duo Mac Installer.zip"
ditto -c -k --keepParent "$STAGE" "build/Duo Mac Installer.zip"
echo "✓ build/Duo Mac Installer.zip"
