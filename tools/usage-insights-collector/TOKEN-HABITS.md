# Cache and token habits: research notes for dashboard suggestions (2026-10-30)

Sources (checked 2026-10-30):
- Claude Code, "How Claude Code uses prompt caching": https://code.claude.com/docs/en/prompt-caching
- Claude Code, "Manage costs effectively": https://code.claude.com/docs/en/costs
- Claude Code, "Best practices": https://code.claude.com/docs/en/best-practices
- Anthropic blog, "Using Claude Code: session management and 1M context" (2026-04-15): https://claude.com/blog/using-claude-code-session-management-and-1m-context
- Claude API, "Prompt caching" and "Optimizing for cost and intelligence": https://platform.claude.com/docs/en/build-with-claude/prompt-caching
- OpenAI, "Prompt caching" guide and "Prompt Caching 201" cookbook: https://developers.openai.com/api/docs/guides/prompt-caching
- Claude Help Center, "Models, usage, and limits in Claude Code": https://support.claude.com/en/articles/14552983
- Claude Help Center, "Usage limit best practices" and "How do usage and length limits work?"
- Claude blog, "Maximizing the value of your Claude Code sessions" (2026-08-14)
- OpenAI Codex docs: Best practices, Models, Pricing (usage tips); OpenAI Help "Using Codex with your ChatGPT plan"
- Community (not official, used only as hints): r/ClaudeCode and r/ClaudeAI threads on making weekly limits last; OpenAI community "Tips on how to minimize Codex usage"
- Context rot research (Chroma, via hamel.dev notes, 2025-09-10)

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

## Second pass (2026-10-30): what else drives usage

Official (Claude Code costs page, Help Center):
- Model choice: Opus costs several times more per turn than Sonnet, Sonnet more than Haiku. Defaults: Sonnet for most coding; Opus when stuck or for wide changes; Haiku for mechanical work. A common pattern is planning with Opus and executing with Sonnet.
- Sub-agents inherit the session model unless set; give simple sub-agents `model: haiku`. Agent teams use about 7x the tokens of a normal session.
- CLAUDE.md is loaded every session: keep it under about 200 lines; move workflow-specific instructions into skills (loaded only when used).
- MCP: tool definitions are deferred by default; prefer CLI tools (gh, gcloud...) and disable unused servers. `/context` in a fresh session shows what is loaded before you type.
- Thinking tokens bill as output; lower effort for simple tasks.
- Hooks can pre-filter verbose output (test logs) before it enters context.
- Write specific prompts; use plan mode for complex work; stop early (Esc) when it heads the wrong way.
- Why usage climbs in a long idle session: long context re-read on every tool call, cache misses after breaks, scheduled tasks and goal check-ins that resend the full context, sub-agents, compaction of a large context.
- `/usage` on subscription plans recommends a change for any behavior behind 10% or more of recent usage.
- Usage limits: a 5-hour session limit and weekly limits, shared by claude.ai, Claude Code and Desktop.

Codex (official):
- Reduce AGENTS.md size (nest per folder), limit MCP servers, switch to a smaller model for routine tasks, pick reasoning effort per task (low for well-scoped work, medium or high for debugging; most tasks do not need max).

Community hints (unverified, reported by users):
- Compacting earlier (around 150K to 400K instead of near 1M) keeps per-message cost close to the old 200K-window behavior.
- Opus plans, Sonnet sub-agents implement; session hand-off notes instead of one endless session.
- Context rot: quality drops as context grows, even on simple tasks (Chroma research), so long sessions cost more and do worse.

## What this PC's records show (2026-10-30, last 30 days)

- Claude Code: conversations over 400K tokens carry 88% of tokens; 216 cache expiries, median gap about 2 hours (1-hour cache, as documented).
- Aside (Claude): 127 cache expiries, median gap 11 minutes, so Aside conversations most likely use a short (5-minute) cache. Not confirmed: Aside does not record the cache lifetime.
- Aside compaction setting: on, at 85% of the model's context window (`compaction.thresholdPercent`). With a 1M-token model a conversation can grow to about 850K before it is compacted, which matches the 80-85만 token conversations seen on the dashboard.
- Codex: no cache expiries detected (consistent with OpenAI's longer retention).
- Claude Code model mix (new tokens): Opus 5.5 75%, Sonnet 5.5 13%, Fable 5.1 8%, Opus 4.6 3%.
- Claude Code short runs on Opus: 1,318 sessions with at most 30 requests and under 150K context used Opus; they are 21% of Claude Code's new tokens. Many look like scripted one-shot runs. Candidates for Sonnet or Haiku.
- Aside (Claude): helper and scheduled work is 55% of new tokens, and 44% is helpers running on Opus (helpers inherit the main model).
- Claude Code settings: `CLAUDE_CODE_AUTO_COMPACT_WINDOW=700000`, so automatic compaction waits until a conversation is very large (peak seen: about 97만 tokens).
- User-level CLAUDE.md: 372 lines (official guidance: under about 200). 7 MCP servers configured at user level (deferred by default, so the per-request cost is mostly their names).

## Which suggestions the dashboard can back with data

| Suggestion | Signal in the records | Status |
|-|-|-|
| Start a new conversation for the next task | long conversation in use (over 400K, last 6 h) | shown now |
| Resume after a break costs a full re-write | cache expiries and the median gap | shown (habit line) |
| Don't switch model mid-conversation | consecutive requests in one session with different models followed by a large cache write | not built yet |
| Lower Aside's compaction point | Aside compaction setting plus Aside conversations over 400K | not built yet; changing the setting needs the owner's approval |
| Rewind instead of correcting, keep CLAUDE.md short, use sub-agents | not visible in token records | advice only, no rule |
| Short runs on Opus could use Sonnet/Haiku | sessions with few requests and small context on an Opus model | new rule candidate |
| Helpers inherit Opus | automated (helper) share and its model | new rule candidate |
| Compact earlier in Claude Code | auto-compact window setting plus peak context | new rule candidate (setting change needs approval) |
| CLAUDE.md over 200 lines | file length | new rule candidate (read-only check) |

## Criteria for the "AI habit check" button (draft)

The model gets only these aggregates and these thresholds, and must quote numbers from the input:
1. Long conversation in use: last request over 400K tokens within 6 h.
2. Long-conversation share: conversations over 400K carry 50% or more of a source's context tokens.
3. Resume after break: re-writes after cache expiry are 15% or more of new tokens.
4. Model switch mid-conversation: 3 or more.
5. Compaction point: Aside or Claude Code compacts later than about 50% of the window while conversations pass 600K.
6. Opus on short runs: 15% or more of new tokens from sessions with at most 30 requests and under 150K context on Opus.
7. Helpers on Opus: helpers are 30% or more of new tokens and mostly on Opus.
8. Re-read hot spots: a project whose re-read total is 50x or more its new tokens.
9. Base context: CLAUDE.md over 200 lines, many MCP servers.
Output: up to 5 actions, each with what, why (numbers from input), and how; nothing else.
