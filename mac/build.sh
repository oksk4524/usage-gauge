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
# local signature (binds Info.plist to the binary; not a Developer ID signature, not notarized).
# A stable self-signed identity in the login keychain keeps the designated requirement the same across
# rebuilds, so macOS does not ask again for keychain access ("Claude Code-credentials") after each build.
# Without that identity it falls back to an ad-hoc signature (which changes on every build).
SIGN_ID="${SIGN_ID:-UsageGauge Local Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGN_ID\""; then
  codesign --force --sign "$SIGN_ID" "$OUT"
else
  echo "warning: code-signing identity \"$SIGN_ID\" not found; using an ad-hoc signature (keychain access will be asked again)" >&2
  codesign --force --sign - "$OUT"
fi
echo "Built $(pwd)/$OUT"
