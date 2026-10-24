#!/bin/bash
# Builds build/DuoMacMicrophone.driver, the virtual microphone (see driver/DuoMacMicrophone.c).
# Installing it needs administrator rights; Duo Mac's setup guide does that (Settings → Setup).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="build/DuoMacMicrophone.driver"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
cp driver/Info.plist "$OUT/Contents/Info.plist"
xcrun --sdk macosx clang -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -O2 -Wall -Wextra -mmacosx-version-min=14.0 -bundle \
  -framework CoreAudio -framework CoreFoundation \
  -o "$OUT/Contents/MacOS/DuoMacMicrophone" driver/DuoMacMicrophone.c
codesign --force --sign - "$OUT" >/dev/null
echo "✓ Built $OUT"
