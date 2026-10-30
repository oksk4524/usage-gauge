#!/bin/bash
# macOS counterpart of tools/usage-insights-collector/install-dashboard.ps1.
# Sets up the local usage dashboard and prepares its 30-minute refresh (launchd LaunchAgent, signed-in user only).
#
#   mac/install-dashboard.sh [--node <path>] [--extra-aside-root <dir>]... [--saved-readings <dir>] [--refresh-now]
#   mac/install-dashboard.sh --activate      # turn the 30-minute refresh on (copies the agent to ~/Library/LaunchAgents and loads it)
#   mac/install-dashboard.sh --deactivate    # turn it off again
#   mac/install-dashboard.sh --uninstall     # turn it off and remove the dashboard folder (usage index and app untouched)
#
# Without --activate nothing starts automatically: the agent file is only written next to the dashboard
# (~/Library/Application Support/UsageGauge/dashboard/com.oksk4524.usagegauge.refresh.plist) and the command to
# turn it on is printed. The refresh reads local log files only: no network, no logins, no credential files.
set -euo pipefail

LABEL="com.oksk4524.usagegauge.refresh"
HOME_DIR="$HOME/Library/Application Support/UsageGauge"
DASH="$HOME_DIR/dashboard"
APP="$DASH/app"
DATA="$DASH/data"
STAGED="$DASH/$LABEL.plist"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

NODE=""; EXTRA=(); SAVED=""; MODE="install"; REFRESH_NOW=0
while [ $# -gt 0 ]; do
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --extra-aside-root) EXTRA+=("$(cd "$2" && pwd)"); shift 2 ;;
    --saved-readings) SAVED="$2"; shift 2 ;;
    --refresh-now) REFRESH_NOW=1; shift ;;
    --activate) MODE="activate"; shift ;;
    --deactivate) MODE="deactivate"; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ "$MODE" = "deactivate" ] || [ "$MODE" = "uninstall" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$AGENT"
  if [ "$MODE" = "uninstall" ]; then rm -rf "$DASH"; echo "Removed the dashboard and its refresh agent. The usage index and the menu bar app are untouched."
  else echo "Refresh agent turned off."; fi
  exit 0
fi

if [ "$MODE" = "activate" ]; then
  [ -f "$STAGED" ] || { echo "Run mac/install-dashboard.sh once first (no prepared agent at $STAGED)." >&2; exit 1; }
  mkdir -p "$HOME/Library/LaunchAgents"
  cp "$STAGED" "$AGENT"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT"
  echo "Refresh agent on: every 30 minutes while you are signed in ($AGENT)."
  exit 0
fi

# ---- install / update (no automatic start) ----
if [ -z "$NODE" ]; then
  for c in "$(command -v node 2>/dev/null || true)" /opt/homebrew/bin/node /usr/local/bin/node; do
    if [ -n "$c" ] && [ -x "$c" ]; then NODE="$c"; break; fi
  done
fi
[ -n "$NODE" ] && [ -x "$NODE" ] || { echo "Node.js not found (needs 22.13 or newer for node:sqlite). Pass --node <path>." >&2; exit 1; }
# a version manager's shim can disappear; keep the real file
NODE="$(cd "$(dirname "$NODE")" && pwd -P)/$(basename "$NODE")"
VER="$("$NODE" --version | sed 's/^v//')"
"$NODE" -e 'const [a,b]=process.argv[1].split(".").map(Number);process.exit(a>22||(a===22&&b>=13)?0:1)' "$VER" \
  || { echo "Node.js $VER is too old (needs 22.13 or newer)." >&2; exit 1; }

# code: same relative layout as the repository, so the modules find each other (same list as install-dashboard.ps1)
FILES=(
  NOTICE WRITING.md assets/service-logos.json
  tools/service-logos.cjs
  tools/usage-insights-collector/collect.cjs tools/usage-insights-collector/indexed.cjs
  tools/usage-insights-collector/assemble.cjs tools/usage-insights-collector/refresh-dashboard.cjs tools/usage-insights-collector/habit-check.cjs
  tools/usage-details-preview-v6/builder.cjs tools/usage-details-preview-v6/client.cjs
  tools/usage-details-preview-v6/core.cjs tools/usage-details-preview-v6/v2.css
  tools/usage-details-preview-v6/template.html
)
for p in "$REPO"/assets/*.png; do [ -f "$p" ] && FILES+=("assets/$(basename "$p")"); done
rm -rf "$APP"
for f in "${FILES[@]}"; do
  [ -f "$REPO/$f" ] || continue
  mkdir -p "$APP/$(dirname "$f")"
  cp "$REPO/$f" "$APP/$f"
done
mkdir -p "$DATA"
printf '%s\n' "$NODE" > "$DASH/node-path"     # the menu bar app runs the "AI 진단" button with this Node

# optional: extra (archived) Aside session folders to read, read-only
if [ ${#EXTRA[@]} -gt 0 ]; then
  "$NODE" -e 'require("fs").writeFileSync(process.argv[1],JSON.stringify({extraAsideRoots:process.argv.slice(2)},null,2))' "$DATA/config.json" "${EXTRA[@]}"
fi
# optional: last saved account readings (masked account labels, no tokens). The refresh never fetches them.
if [ -n "$SAVED" ]; then
  for pair in "codex.jsonl:codex.jsonl" "final-limits.jsonl:limits.jsonl" "ag.jsonl:antigravity-limits.jsonl"; do
    src="$SAVED/${pair%%:*}"; dst="$DATA/${pair##*:}"
    [ -f "$src" ] || continue
    if grep -Eq '"(access_token|refresh_token|id_token|authorization|password)"[[:space:]]*:|eyJ[A-Za-z0-9_-]{10,}\.' "$src"; then
      echo "${pair%%:*} looks like it contains a credential; not copied." >&2; exit 1
    fi
    cp "$src" "$dst"
  done
fi

# the agent: current user's GUI session only, every 30 minutes and once at login, low priority, no network use
SCRIPT="$APP/tools/usage-insights-collector/refresh-dashboard.cjs"
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
cat > "$STAGED" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(xml "$NODE")</string>
		<string>--no-warnings</string>
		<string>$(xml "$SCRIPT")</string>
	</array>
	<key>WorkingDirectory</key>
	<string>$(xml "$DATA")</string>
	<key>StartInterval</key>
	<integer>1800</integer>
	<key>RunAtLoad</key>
	<true/>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityIO</key>
	<true/>
	<key>Nice</key>
	<integer>10</integer>
	<key>ExitTimeOut</key>
	<integer>30</integer>
	<key>StandardOutPath</key>
	<string>/dev/null</string>
	<key>StandardErrorPath</key>
	<string>$(xml "$DATA/launchd-stderr.log")</string>
</dict>
</plist>
PLIST
plutil -lint "$STAGED" >/dev/null

if [ "$REFRESH_NOW" = 1 ]; then
  echo "Building the page once (the first run reads all local logs)..."
  (cd "$DATA" && "$NODE" --no-warnings "$SCRIPT") || echo "First refresh failed; see $DATA/refresh.log" >&2
fi

echo "Installed. Page: $DASH/usage-gauge.html"
echo "Automatic 30-minute refresh is NOT on yet. To turn it on:  $0 --activate"
