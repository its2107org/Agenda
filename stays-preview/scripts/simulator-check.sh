#!/bin/bash
# Builds Stays for the iPhone simulator, runs its self-check, and takes screenshots of the main
# screens with pretend to-dos in light and dark mode.
set -eo pipefail

UDID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
c=[x for r,l in d.items() if "iOS" in r for x in l if x["name"].startswith("iPhone") and "Pro" in x["name"] and "Max" not in x["name"]]
c.sort(key=lambda x:x["name"])
print(c[-1]["udid"])')
echo "Using simulator $UDID"

xcodebuild -project Stays.xcodeproj -scheme Stays -configuration Debug -sdk iphonesimulator \
  -destination "id=$UDID" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build.log | grep -E "error:|warning: unre|BUILD (SUCCEEDED|FAILED)" || true
grep -q "BUILD SUCCEEDED" build.log || { echo "::error::Build failed"; grep -E "error:" build.log | sort -u | head -80; exit 1; }

APP=build/Build/Products/Debug-iphonesimulator/Stays.app
BID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist")

xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 || true
xcrun simctl install "$UDID" "$APP"
mkdir -p shots

# 1. Self-check (includes looking for real hotel photos online).
xcrun simctl launch --terminate-running-process "$UDID" "$BID" -StaysSelfTest
for i in $(seq 1 150); do
  DATA=$(xcrun simctl get_app_container "$UDID" "$BID" data)
  [ -f "$DATA/Documents/selftest.json" ] && break
  sleep 2
done
if [ -f "$DATA/Documents/selftest.json" ]; then
  cp "$DATA/Documents/selftest.json" shots/selftest.json
  cp "$DATA"/Documents/found-*.jpg shots/ 2>/dev/null || true
  cat shots/selftest.json
  grep -q '"all passed"' shots/selftest.json || { echo "::error::Self-check failed"; exit 1; }
else
  echo "::error::Self-check produced no result"
  DATA=$(xcrun simctl get_app_container "$UDID" "$BID" data)
  while read -r l; do echo "::error::progress: $l"; done < <(tail -20 "$DATA/Documents/selftest-progress.txt" 2>/dev/null || echo none)
  for f in $(ls -t ~/Library/Logs/DiagnosticReports/Stays* 2>/dev/null | head -1); do head -c 3000 "$f" | grep -E "Exception|Termination|Crashed|^[0-9]+ +Stays" | head -20 | while read -r l; do echo "::error::crash: $l"; done; done
  exit 1
fi
xcrun simctl terminate "$UDID" "$BID" || true

# 2. Screenshots with a pretend list. The first launch finds real photos online, so give it time.
xcrun simctl launch --terminate-running-process "$UDID" "$BID" -StaysDemo
for i in $(seq 1 60); do
  DATA=$(xcrun simctl get_app_container "$UDID" "$BID" data)
  [ "$(ls "$DATA/Documents/DemoLibrary/people" 2>/dev/null | wc -l)" -ge 2 ] && break
  sleep 2
done
sleep 4
shoot() { # name, extra args
  local name=$1; shift
  xcrun simctl launch --terminate-running-process "$UDID" "$BID" -StaysDemo "$@"
  sleep 6
  xcrun simctl io "$UDID" screenshot "shots/$name.png"
}
for mode in light dark; do
  xcrun simctl ui "$UDID" appearance $mode
  shoot "list-$mode"
  shoot "detail-$mode" -StaysDemoDetail
  shoot "rate-$mode" -StaysDemoRate
  shoot "map-$mode" -StaysDemoMap
  shoot "bestpool-$mode" -StaysDemoBestPool
  shoot "settings-$mode" -StaysDemoSettings
  shoot "invite-$mode" -StaysDemoInvite
  shoot "welcome-$mode" -StaysDemoWelcome
done
xcrun simctl ui "$UDID" appearance light
shoot "search-light" -StaysDemoSearch
sleep 4; xcrun simctl io "$UDID" screenshot "shots/search-light-2.png"
xcrun simctl launch --terminate-running-process "$UDID" "$BID" -StaysDemo -StaysDemoAddDetails
sleep 25
xcrun simctl io "$UDID" screenshot "shots/adddetails-light.png"
ls -la shots
