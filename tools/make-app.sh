#!/bin/bash
# Creates /Applications/Duo Mac.app: a tiny launcher that owns the macOS permissions and starts the
# helper. Only rebuild it when the launcher itself changes — macOS ties permissions to this exact build.
# It lives in /Applications so Spotlight, Raycast and Launchpad list it like any other app.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${DUO_MAC_APP:-/Applications/Duo Mac.app}"
echo "▸ Building launcher app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/DuoMac" launcher/main.swift
[ -d build/AppIcon.iconset ] || swift tools/make-icons.swift "$PWD"
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.riccardoconti.duomac</string>
  <key>CFBundleName</key><string>Duo Mac</string>
  <key>CFBundleDisplayName</key><string>Duo Mac</string>
  <key>CFBundleExecutable</key><string>DuoMac</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Duo Mac lets your iPhone on the same network show and control this Mac.</string>
  <key>NanoHelperPath</key><string>$PWD/build/Duo Mac</string>
</dict>
</plist>
PLIST
xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "✓ Built $APP"
