#!/bin/bash
# driftwatch — install + run the capture on a connected iPhone, decode the
# console-streamed capture, save it under captures/, and diff it against the
# macOS baseline. Device must be unlocked and on the same network (or USB).
#
# usage: scripts/capture_iphone.sh [device-udid]
set -euo pipefail

cd "$(dirname "$0")/.."
DEVICE="${1:-4A08EA6E-44A6-53E8-8829-852BEB69AF36}"
APP="runner/build/ios/iphoneos/Runner.app"
BUNDLE_ID="com.umer9538.driftwatchRunner"
CONSOLE_LOG="$(mktemp /tmp/driftwatch-console.XXXXXX)"

if [ ! -d "$APP" ]; then
  echo "app not built — running flutter build ios --release first"
  (cd runner && flutter build ios --release)
fi

echo "installing $BUNDLE_ID on $DEVICE …"
xcrun devicectl device install app --device "$DEVICE" "$APP"

echo "launching with console (suite takes ~5-10 min on device) …"
xcrun devicectl device process launch --console --device "$DEVICE" "$BUNDLE_ID" \
  >"$CONSOLE_LOG" 2>&1 &
LAUNCH_PID=$!

# Wait for the END marker (or the app/connection dying), up to 20 minutes.
for _ in $(seq 1 240); do
  if grep -q "DRIFTWATCH-END" "$CONSOLE_LOG" 2>/dev/null; then break; fi
  if grep -q "DRIFTWATCH-ERROR" "$CONSOLE_LOG" 2>/dev/null; then break; fi
  if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then break; fi
  sleep 5
done
kill "$LAUNCH_PID" 2>/dev/null || true

if grep -q "DRIFTWATCH-ERROR" "$CONSOLE_LOG"; then
  echo "capture FAILED on device:"
  grep "DRIFTWATCH-ERROR" "$CONSOLE_LOG"
  echo "(full console: $CONSOLE_LOG)"
  exit 1
fi
if ! grep -q "DRIFTWATCH-END" "$CONSOLE_LOG"; then
  echo "no capture markers seen — console log: $CONSOLE_LOG"
  tail -5 "$CONSOLE_LOG"
  exit 1
fi

python3 - "$CONSOLE_LOG" <<'EOF'
import base64, json, re, sys

chunks = {}
for line in open(sys.argv[1], errors="replace"):
    m = re.search(r"DW(\d+):([A-Za-z0-9+/=]+)", line)
    if m:
        chunks[int(m.group(1))] = m.group(2)
if not chunks:
    sys.exit("markers seen but no chunks decoded")
encoded = "".join(chunks[i] for i in sorted(chunks))
capture = base64.b64decode(encoded).decode("utf-8")
doc = json.loads(capture)
build = doc["platform"]["osBuild"]
path = f"captures/apple/{build}/{doc['suite']}-v{doc['suiteVersion']}.capture.json"
import os
os.makedirs(os.path.dirname(path), exist_ok=True)
open(path, "w").write(capture)
print(f"capture saved: {path}")
print(f"  iOS {doc['platform']['osVersion']} ({build}), "
      f"fm {doc['model'].get('frameworkBuild')}, "
      f"{len(doc['results'])} prompts")
EOF

echo
echo "=== drift vs macOS baseline ==="
IOS_CAPTURE=$(ls -t captures/apple/*/driftwatch-core-v1.capture.json | head -1)
dart diff/bin/driftwatch_diff.dart \
  captures/apple/25F80/driftwatch-core-v1.capture.json "$IOS_CAPTURE" || true
