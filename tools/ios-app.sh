#!/bin/bash
# The Duo Mac iPhone app (ios/): builds it, installs it on your iPhone, and keeps it installed.
#
# Signed with a free Apple ID ("Personal Team"), an installed copy stops opening 7 days after it was
# built. So this also sets up an hourly job on the Mac that rebuilds and reinstalls the app when less
# than a day and a half is left, whenever the iPhone is reachable (cable, or the same Wi-Fi/hotspot)
# and the app isn't in use.
#
#   tools/ios-app.sh             build and install now, and set up the hourly job
#   tools/ios-app.sh --refresh   what the hourly job runs: only when the installed copy expires soon
#   tools/ios-app.sh --remove    stop the hourly job
#
# First time: plug the iPhone in, open ios/DuoMac.xcodeproj in Xcode and pick your team under
# Signing & Capabilities, and turn on Developer Mode on the iPhone (Settings › Privacy & Security).
set -uo pipefail

MODE="${1:-}"
SUPPORT="$HOME/Library/Application Support/Duo Mac"
WORK="$SUPPORT/ios-app"            # a copy of ios/ + this script: the hourly job can't read ~/Documents
STATE="$WORK/state"
LOG="$WORK/log.txt"
LABEL="com.riccardoconti.duomac.ios-refresh"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
REFRESH_BEFORE=$((36 * 3600))      # reinstall when less than this is left
mkdir -p "$WORK"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$HERE/ios"
[ -d "$SRC" ] || SRC="$WORK/ios"   # running as the hourly job, from the copy

say() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG" >&2; }
get() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" | tail -1; }
put() { touch "$STATE"; grep -v "^$1=" "$STATE" > "$STATE.tmp"; echo "$1=$2" >> "$STATE.tmp"; mv "$STATE.tmp" "$STATE"; }

if [ "$MODE" = "--remove" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
  rm -f "$AGENT"
  say "Hourly renewal stopped"
  exit 0
fi

# ── When does the installed copy stop opening? ──
NOW=$(date +%s)
EXPIRES=$(get expires)
if [ "$MODE" = "--refresh" ] && [ -n "$EXPIRES" ] && [ $((EXPIRES - NOW)) -gt $REFRESH_BEFORE ]; then
  exit 0 # plenty of time left
fi

# ── Team (picked once in Xcode) and the Mac's address ──
# The team: $DUO_TEAM, else the one picked in Xcode for the project, else the Apple ID's Personal Team
# (Xcode › Settings › Accounts), else its first team.
TEAM="${DUO_TEAM:-$(sed -n 's/.*DEVELOPMENT_TEAM = \([A-Z0-9]\{10\}\);.*/\1/p' "$SRC/DuoMac.xcodeproj/project.pbxproj" | head -1)}"
if [ -z "$TEAM" ]; then
  TEAM=$(/usr/bin/defaults export com.apple.dt.Xcode - 2>/dev/null | /usr/bin/python3 -c '
import plistlib, sys
try:
    teams = [t for ts in plistlib.loads(sys.stdin.buffer.read()).get("IDEProvisioningTeamByIdentifier", {}).values() for t in ts]
except Exception:
    teams = []
teams.sort(key=lambda t: not t.get("isFreeProvisioningTeam"))
print(teams[0]["teamID"] if teams else "")' 2>/dev/null)
fi
if [ -z "$TEAM" ]; then
  say "No team yet: add your Apple ID in Xcode › Settings › Accounts (or set DUO_TEAM)."
  exit 1
fi
# The address Duo Mac serves at now (the Tailscale app's, or its built-in one's), else the app's.
HOST=$(sed -n 's#^https://\([^/]*\)/*$#\1#p' "$SUPPORT/url.txt" 2>/dev/null | head -1)
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
[ -n "$HOST" ] || HOST=$("$TS" status --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null)
[ -n "$HOST" ] || HOST=$(get host)
if [ -z "$HOST" ]; then say "Can't tell this Mac's Tailscale address: is Tailscale running?"; exit 1; fi
put host "$HOST"

# ── The iPhone: paired with this Mac and reachable now ──
J="$WORK/devices.json"
/usr/bin/xcrun devicectl list devices --json-output "$J" >/dev/null 2>&1
read -r DEVICE UDID NAME < <(/usr/bin/python3 - "$J" "$(get device)" <<'EOF'
import json, sys
try:
    devs = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devs = []
want = sys.argv[2]
ok = []
for d in devs:
    hw, cp = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hw.get("platform") != "iOS" or hw.get("deviceType") not in (None, "iPhone"):
        continue
    if cp.get("pairingState") != "paired" or cp.get("tunnelState") == "unavailable":
        continue
    ok.append((d["identifier"] == want or hw.get("udid") == want, d["identifier"], hw.get("udid", ""),
               d.get("deviceProperties", {}).get("name", "iPhone").replace(" ", "_")))
ok.sort(reverse=True)
print(" ".join(ok[0][1:]) if ok else "")
EOF
)
if [ -z "${DEVICE:-}" ]; then
  [ "$MODE" = "--refresh" ] || say "No iPhone found: plug it in (and tap Trust), or put it on the same Wi-Fi as the Mac."
  exit 1
fi
NAME="${NAME//_/ }"

# Don't pull the app out from under you: wait while it's open, unless it's about to stop opening.
if [ "$MODE" = "--refresh" ] && [ -n "$EXPIRES" ] && [ $((EXPIRES - NOW)) -gt 21600 ]; then
  P="$WORK/procs.json"
  if /usr/bin/xcrun devicectl device info processes --device "$DEVICE" --json-output "$P" >/dev/null 2>&1 \
     && grep -q 'Duo%20Mac.app/\|Duo Mac.app/' "$P"; then
    say "Duo Mac is open on $NAME: renewing later"
    exit 0
  fi
fi

# ── A fresh 7-day signature: drop the old profiles so Xcode makes new ones ──
# (Then a clean build: the last build's record still points at the profiles just removed.)
RENEWED=
# The app's and its widget extension's (…phone.widget): each has its own profile, and the extension's
# expiring first would break the widgets before the app.
BUNDLE=$(sed -n 's/.*PRODUCT_BUNDLE_IDENTIFIER = \([^;]*\);.*/\1/p' "$SRC/DuoMac.xcodeproj/project.pbxproj" | head -1)
for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*.mobileprovision; do
    [ -f "$f" ] || continue
    if /usr/bin/security cms -D -i "$f" 2>/dev/null | grep -q "<string>$TEAM\.$BUNDLE[.<]"; then rm -f "$f"; RENEWED=1; fi
  done
done

# ── Tailscale inside the app (libtailscale): built once ──
if [ ! -f "$SRC/Tailscale/libtailscale_ios.a" ] && [ -x "$HERE/tools/build-libtailscale.sh" ]; then
  say "Building Tailscale for the app (once; a few minutes)…"
  "$HERE/tools/build-libtailscale.sh" > "$WORK/libtailscale.log" 2>&1 || { say "Couldn't build Tailscale (see $WORK/libtailscale.log)"; exit 1; }
fi

# ── Build ──
say "Building Duo Mac for $NAME (team $TEAM, Mac at $HOST)…"
if [ "$SRC" != "$WORK/ios" ]; then rsync -a --delete "$SRC/" "$WORK/ios/"; cp "$0" "$WORK/ios-app.sh"; fi
DD="$WORK/build"
build() {
  /usr/bin/xcodebuild -project "$WORK/ios/DuoMac.xcodeproj" -scheme DuoMac -configuration Release \
    -destination "id=$UDID" -derivedDataPath "$DD" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$TEAM" DUO_MAC_URL="https://$HOST/" DUO_MAC_HOST="$HOST" DUO_TAILNET="${HOST#*.}" "$@" > "$WORK/xcodebuild.log" 2>&1
}
# Right after the old profiles are removed, Xcode can still reach for one of them ("Build input file
# cannot be found: …mobileprovision"); the next try makes new ones.
if ! build ${RENEWED:+clean} build && ! { grep -q "mobileprovision" "$WORK/xcodebuild.log" && build build; }; then
  grep -E "error:" "$WORK/xcodebuild.log" | head -5 | while read -r l; do say "  $l"; done
  say "Build failed (full log: $WORK/xcodebuild.log)"
  exit 1
fi
APP="$DD/Build/Products/Release-iphoneos/Duo Mac.app"

# ── Install ──
if ! /usr/bin/xcrun devicectl device install app --device "$DEVICE" "$APP" > "$WORK/install.log" 2>&1; then
  tail -5 "$WORK/install.log" | while read -r l; do say "  $l"; done
  say "Couldn't install on $NAME (is it unlocked, with Developer Mode on?)"
  exit 1
fi
EXP=$(/usr/bin/security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | /usr/bin/plutil -extract ExpirationDate raw -o - - 2>/dev/null)
EXP_S=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$EXP" +%s 2>/dev/null || echo "")
put device "$DEVICE"
[ -n "$EXP_S" ] && put expires "$EXP_S"
say "Installed on $NAME. This copy opens until $(date -r "${EXP_S:-0}" '+%a %d %b %H:%M')."

# ── The hourly job ──
if [ "$MODE" != "--refresh" ]; then
  cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$WORK/ios-app.sh</string><string>--refresh</string></array>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
  launchctl bootstrap "gui/$(id -u)" "$AGENT" && say "Hourly renewal is on (log: $LOG)"
fi
