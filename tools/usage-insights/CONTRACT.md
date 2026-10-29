# UsageGauge snapshot contract v1

This is the shared read-only snapshot format for UI, CLI and MCP. All strings derived from private files must be masked/whitelisted. No conversation text, auth tokens, email, raw paths or original project/session IDs.

Top-level object:
- schemaVersion: "1.0"
- snapshotId: opaque stable ID
- generatedAt: ISO timestamp of snapshot publication (not collection time)
- timezone: IANA name e.g. "Asia/Seoul"
- period: {from:"YYYY-MM-DD",to:"YYYY-MM-DD"}, the local calendar horizon collected
- datasets: array of datasets (NEVER sum across datasets automatically)
- limits: array of {id,provider,source,scope:"account",window,model:null|string,usedPercent:null|number,remainingPercent:null|number,resetAt:null|ISO,capturedAt:ISO,unit:"percent"|"credits",remainingCredits:null|number,status:"observed"|"unavailable",reason:null|string,accountId:null|opaque,accountLabel:null|masked}
  - accountId is a one-way key of the signed-in account the quota was read with; accountLabel is a pre-masked label ("ab***@domain" or "ab***"). Any unmasked label is dropped. Antigravity exposes no account and stays null. Quotas from different accounts are never comparable to each other or to local logs.
- costs: {status:"unavailable"|"observed",actualSubscription:null,actualAdditionalCharges:null,apiEquivalentEstimate:null,reason:string}
- outcomes: {status:"unavailable",reason:string}
- capabilities: object of statuses (not promises)
- notes: array of fixed machine codes

Each dataset:
- id: e.g. "claude_cli_local", "codex_account"
- provider: "claude"|"grok"|"antigravity"|"codex"|other known provider
- source: stable adapter name
- scope: "this_device" or "account"
- deviceId: "local" or null, accountId: null unless explicitly safely distinguished
- Local (this_device) datasets always carry the warning accounts_not_separable: local logs have no account field, so usage from every account signed in on the PC is mixed and cannot be split by account.
- capturedAt: real collection time of that source
- latestEventAt: ISO or null (not inferred from file mtime)
- latestCompleteDate: YYYY-MM-DD or null (cannot assume today's complete)
- semantics: {id,totalRule,inputIncludesCache:boolean|null,outputIncludesReasoning:boolean|null,cacheReadIncludedInTotal:boolean|null,verified:"source_fields"|"documented"|"assumed",warnings:[codes]}
- coverage: {status:"complete_for_selected_source"|"partial"|"unavailable",issues:[codes],filesFound:number|null,invalidRecords:number|null,unmeteredRecords:number|null,duplicateRecords:number|null,missingDates:[YYYY-MM-DD],comparisonSafe:boolean,comparisonReason:null|string}
- totals: {input:null|integer,output:null|integer,cacheRead:null|integer,cacheCreate:null|integer,reasoning:null|integer,total:null|integer,records:null|integer}
- days: [{date:"YYYY-MM-DD",tokens:null|integer,input:null|integer,output:null|integer,cacheRead:null|integer,cacheCreate:null|integer,reasoning:null|integer,records:integer|null,coverageStatus:"observed"|"missing"|"partial"}]
- breakdowns: {project:[],session:[],model:[],attribution:[]}; each entry {date,id,label,totals:{same Counts}}. Project/session labels must be masked, e.g. Project a1b2c3 / Session 91ab. Unknown is a real bucket, never guessed. All sums must match day totals for supported dimensions.
- activity: [{date,hour:0..23,attribution:"unknown"|"direct"|"automated",tokens,records}]. These are event-time counts, NOT active hours, working hours, sleep or productivity.
- diagnostics: safe fixed codes and counts only. No arbitrary source strings or private paths.

Query semantics:
- period "7d", "30d", "all" ends on snapshot.period.to, never silently current wall clock; return period and capturedAt to expose staleness.
- period "7d"/"30d" start at snapshot.period.to minus 6/29 days (clamped to snapshot.period.from). period "all" ends on snapshot.period.to and starts per dataset at the earliest date declared in that dataset's days[] (a day with null totals still counts); if days[] is empty it falls back to snapshot.period.from. Top-level period stays the global query range; every dataset result carries selectedPeriod {from,to}, the range actually used by selectedCoverage, summary, breakdown and habits, so dates outside a dataset's collection window are not reported as missing.
- Aside recovery dataset (id aside_unattributed, provider aside, source aside_turns) is accepted by the existing id pattern, provider enum and source allowlist; no allowlist change.
- provider/dataset filters retain datasets separate. Missing records != zero use. Unsupported fields must remain null/status unsupported.
- summary returns per-dataset selected-day totals, source/semantics/coverage, date range and stale age. No combined provider total.
- breakdown returns per-dataset rows aggregated by dimension project/session/model/attribution over period, top limit (default10 max50) plus exact remainder and total. No across-source ranking.
- limits returns observed limits plus earliest_reset and lowest_remaining only among eligible comparable percent windows per provider. No invented remaining hours or quota forecasts.
- diagnostics returns snapshot status, dataset coverage, unsupported data and limits age.
- habits returns hourly event distribution and peak-day observations by dataset, explicit NOT working-hours caveat; no behavior attribution without evidence.
- costs returns actual/estimated/unavailable separately, never claims savings.

Read-only CLI/MCP only reads one startup-configured snapshot file. It never reads provider logs/auth files, performs scans/network requests, starts CLIs, changes settings or refreshes credentials. Refresh/export is separate parent-owned collector operation. Cloud-hosted AI may receive returned aggregates; mask names by default and disclose it.

- breakdowns may include an app dimension (where the usage was produced): aside, grok_cli, antigravity_cli, claude_vscode, claude_cli, claude_desktop, claude_sdk_cli, claude_sdk_ts, claude_sdk_py, codex_exec, codex_vscode, codex_desktop, codex_cli, codex_in_claude_code or unknown. Snapshots without it remain valid; breakdown --by app then reports unsupported.
- codex_cli_local (source codex_session_logs) reads Codex app/CLI rollouts (.jsonl and compressed .jsonl.zst). input is the uncached part; input + cacheRead + cacheCreate + output equals the reported total_tokens. It covers only this PC and is never added to codex_account.
