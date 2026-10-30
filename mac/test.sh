#!/bin/bash
# Logic tests for the menu bar app, run with the Swift interpreter (no app bundle needed), then a check that the
# collector's assemble.cjs accepts the app's limits.jsonl.
#   mac/test.sh
set -euo pipefail
cd "$(dirname "$0")"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# script mode: all sources without the @main entry point, then the tests as top-level code
cat Sources/Usage.swift Sources/Antigravity.swift Sources/DashboardFeed.swift Sources/Design.swift Sources/PopoverView.swift Sources/MenuBarGlyphs.swift Sources/MenuBarStrip.swift > "$TMP/all.swift"
sed '/^@main/,$d' Sources/App.swift >> "$TMP/all.swift"
cat Tests/LogicTests.swift >> "$TMP/all.swift"
swift -swift-version 5 "$TMP/all.swift" "$TMP/limits.jsonl"
NODE="${NODE:-$(command -v node || echo /opt/homebrew/bin/node)}"
mkdir -p "$TMP/emptyhome"
"$NODE" --no-warnings -e '
(async()=>{
const path=require("path"),{assemble,saved}=require(process.argv[1]),{collect}=require(path.join(path.dirname(process.argv[1]),"collect.cjs"));
const local=await collect({home:process.argv[3]});   // an empty home: no logs, only the limits feed matters here
const s=assemble(local,{limits:saved(process.argv[2]),codex:saved(null),antigravity:saved(null)});
const ok=s.limits.filter(l=>l.status!=="unavailable").map(l=>l.provider+":"+l.window+":"+l.usedPercent);
if(!ok.includes("codex:7d:40")||!ok.includes("claude:7d:33.3"))throw Error("assemble did not read the app feed: "+JSON.stringify(ok));
const acct=s.limits.find(l=>l.provider==="codex"&&l.window==="7d");
if(!acct.accountId||acct.accountLabel!=="pe***@example.com")throw Error("account label not accepted: "+JSON.stringify(acct));
console.log("PASS assemble.cjs reads the app limits feed ("+ok.join(", ")+"; account "+acct.accountLabel+")");
})().catch(e=>{console.error(e.message);process.exit(1);});
' "$(pwd)/../tools/usage-insights-collector/assemble.cjs" "$TMP/limits.jsonl" "$TMP/emptyhome"
