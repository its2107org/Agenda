#!/bin/bash
# Builds Agenda for the iPhone simulator, runs its self-check, and takes screenshots of the main
# screens with pretend to-dos in light and dark mode.
set -eo pipefail

UDID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
c=[x for r,l in d.items() if "iOS" in r for x in l if x["name"].startswith("iPhone") and "Pro" in x["name"] and "Max" not in x["name"]]
c.sort(key=lambda x:x["name"])
print(c[-1]["udid"])')
echo "Using simulator $UDID"

xcodebuild -project Agenda.xcodeproj -scheme Agenda -configuration Debug -sdk iphonesimulator \
  -destination "id=$UDID" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build.log | grep -E "error:|warning: unre|BUILD (SUCCEEDED|FAILED)" || true
grep -q "BUILD SUCCEEDED" build.log || { echo "::error::Build failed"; grep -E "error:" build.log | sort -u | head -80; exit 1; }

APP=build/Build/Products/Debug-iphonesimulator/Agenda.app
BID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist")

xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 || true
xcrun simctl install "$UDID" "$APP"
mkdir -p shots

# 1. Self-check.
xcrun simctl launch --terminate-running-process "$UDID" "$BID" -AgendaSelfTest
for i in $(seq 1 30); do
  DATA=$(xcrun simctl get_app_container "$UDID" "$BID" data)
  [ -f "$DATA/Documents/selftest.json" ] && break
  sleep 2
done
if [ -f "$DATA/Documents/selftest.json" ]; then
  cp "$DATA/Documents/selftest.json" shots/selftest.json
  cat shots/selftest.json
  grep -q '"all passed"' shots/selftest.json || { echo "::error::Self-check failed"; exit 1; }
else
  echo "::error::Self-check produced no result"
  exit 1
fi
xcrun simctl terminate "$UDID" "$BID" || true

# 2. Screenshots with pretend to-dos.
shoot() { # name, extra args
  local name=$1; shift
  xcrun simctl launch --terminate-running-process "$UDID" "$BID" -AgendaDemo "$@"
  sleep 6
  xcrun simctl io "$UDID" screenshot "shots/$name.png"
}
for mode in light dark; do
  xcrun simctl ui "$UDID" appearance $mode
  shoot "today-$mode"
  shoot "lists-$mode" -AgendaDemoLists
  shoot "calendar-$mode" -AgendaDemoCalendar
  shoot "reminders-$mode" -AgendaDemoReminders
  shoot "dump-$mode" -AgendaDemoDump
  shoot "review-$mode" -AgendaDemoReview
  shoot "booking-$mode" -AgendaDemoBooking
  shoot "settings-$mode" -AgendaDemoSettings
done
ls -la shots
