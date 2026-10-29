# Cache and token habits: research notes for dashboard suggestions (2026-10-30)

Sources (checked 2026-10-30):
- Claude Code, "How Claude Code uses prompt caching": https://code.claude.com/docs/en/prompt-caching
- Claude Code, "Manage costs effectively": https://code.claude.com/docs/en/costs
- Claude Code, "Best practices": https://code.claude.com/docs/en/best-practices
- Anthropic blog, "Using Claude Code: session management and 1M context" (2026-04-15): https://claude.com/blog/using-claude-code-session-management-and-1m-context
- Claude API, "Prompt caching" and "Optimizing for cost and intelligence": https://platform.claude.com/docs/en/build-with-claude/prompt-caching
- OpenAI, "Prompt caching" guide and "Prompt Caching 201" cookbook: https://developers.openai.com/api/docs/guides/prompt-caching

## How the caches behave

| | Claude Code (subscription) | Claude API / usage credits | OpenAI (Codex) |
|-|-|-|-|
| Main conversation cache life | 1 hour | 5 minutes | about 30 min active, kept up to 24 h on current models |
| Sub-agents | 5 minutes | 5 minutes | |
| Re-read price | cached-token rate (0.1x input; 0.05x on Opus/Sonnet 5.5) | same | discounted up to 90-95% |
| Write price | 1h write 2x input, 5m write 1.25x | | no write surcharge |

- The cache matches the request from its start (prefix). A change anywhere in the prefix recomputes everything after it.
- Breaks the cache (next turn re-reads the whole history at full input price): switching model, changing effort (except Opus/Sonnet/Haiku 5.5 and Fable 5.1 on subscription or API key), toggling fast mode, adding or removing tools/MCP servers loaded up front, compaction (by design), many images (oldest dropped), Claude Code upgrade (first turn).
- Keeps the cache: editing files, editing CLAUDE.md mid-session (applies only after /clear, /compact or restart), permission mode, output style, skills and commands, /recap, /rewind, sub-agents (own cache), forks (share the parent cache).
- Idle on the 1-hour cache: a Claude Code session over about 200K tokens is compacted shortly before the cache expires (setting `idleCompaction`).
- `/compact` while the cache is warm costs little; after a break longer than the cache life it re-reads the whole history uncached, so compacting an old resumed session is the expensive case.
- OpenAI: compaction or dropping earlier turns also breaks the cache; dynamic content (timestamps) early in the prompt breaks it.

## Recommended habits (official guidance)

1. New task, new session: `/clear` between unrelated tasks; `/clear <name>` keeps the old one resumable.
2. Correct by rewinding, not by arguing: after two failed corrections, `/rewind` (Esc Esc) to before the failed attempt and re-prompt with what you learned. Rewinding reuses the cached prefix.
3. Compact at natural breaks with a focus (`/compact keep the API changes and test commands`), not mid-task and not after a long break.
4. Pick model and effort at the start of a session; do not switch mid-task.
5. Work that produces lots of output you only need the conclusion of (searching a codebase, verification, docs) goes to a sub-agent.
6. Keep CLAUDE.md short: it is part of every request.
7. Use `/usage` (Claude Code) for a per-session cache line: hit ratio, misses, likely cause of the last miss, warm or cold.

## What this PC's records show (2026-10-30, last 30 days)

- Claude Code: conversations over 400K tokens carry 88% of tokens; 216 cache expiries, median gap about 2 hours (1-hour cache, as documented).
- Aside (Claude): 127 cache expiries, median gap 11 minutes, so Aside conversations most likely use a short (5-minute) cache. Not confirmed: Aside does not record the cache lifetime.
- Aside compaction setting: on, at 85% of the model's context window (`compaction.thresholdPercent`). With a 1M-token model a conversation can grow to about 850K before it is compacted, which matches the 80-85만 token conversations seen on the dashboard.
- Codex: no cache expiries detected (consistent with OpenAI's longer retention).

## Which suggestions the dashboard can back with data

| Suggestion | Signal in the records | Status |
|-|-|-|
| Start a new conversation for the next task | long conversation in use (over 400K, last 6 h) | shown now |
| Resume after a break costs a full re-write | cache expiries and the median gap | shown (habit line) |
| Don't switch model mid-conversation | consecutive requests in one session with different models followed by a large cache write | not built yet |
| Lower Aside's compaction point | Aside compaction setting plus Aside conversations over 400K | not built yet; changing the setting needs the owner's approval |
| Rewind instead of correcting, keep CLAUDE.md short, use sub-agents | not visible in token records | advice only, no rule |
