#!/bin/bash
# Builds mac/build/UsageGauge.app with the Swift command line tools (no Xcode project).
#   mac/build.sh
# Does not install anything: copying the app to /Applications and starting it at login are separate, manual steps.
set -euo pipefail
cd "$(dirname "$0")"
OUT=build/UsageGauge.app
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework Security -framework SwiftUI \
  Sources/*.swift -o "$OUT/Contents/MacOS/UsageGauge"
cp Info.plist "$OUT/Contents/Info.plist"
# service logos (light screens use the -dark variants)
mkdir -p "$OUT/Contents/Resources/logos"
for f in codex codex-dark claude grok grok-dark gemini; do cp "../assets/$f.png" "$OUT/Contents/Resources/logos/"; done
plutil -lint "$OUT/Contents/Info.plist" >/dev/null
# local ad-hoc signature (binds Info.plist to the binary; not a Developer ID signature, not notarized)
codesign --force --sign - "$OUT"
echo "Built $(pwd)/$OUT"
