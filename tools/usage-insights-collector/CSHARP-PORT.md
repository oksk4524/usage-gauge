# Moving the collector into the widget: feasibility (2026-10-30)

Goal: the widget collects by itself (file-change driven), so no Node process and no scheduled task are needed.
Budget, counted for widget + collector together: about +10 MB memory and +0.1 s CPU per minute on average.

## What was checked

| Question | Result |
|-|-|
| SQLite without Node or NuGet | Works. `winsqlite3.dll` ships with Windows 10/11 (here 3.53.4). P/Invoke from the .NET Framework `csc` the widget already uses. Probe: `SqliteProbe.cs` pattern, read-only open. |
| Same numbers as Node | Yes. Row counts, token totals and 1-hour cache writes for all 8 datasets in the index matched `node:sqlite` exactly. |
| Cost of reading the index | Separate probe process: peak working set 19 MB (private 14 MB), 0.45 to 0.83 s CPU for a full scan of a 72 MB index. Inside the widget the extra memory is lower (runtime already loaded), and normal runs only touch changed rows. |
| `.jsonl.zst` (compressed Codex rollouts) | No decoder in Windows or .NET Framework. Codex compresses rollouts about 8 days after they stop changing; a compressed file never changes again. Here: 115 compressed (231 MB, last one 2026-10-21), 225 plain. |

## Plan

1. Keep the index format and rules (`indexed.cjs`, RULES_VERSION) as the single source of truth. C# reads and writes the same tables.
2. Port per source, in this order, each checked against Node on the same input until results are identical:
   Claude CLI (largest, append-only) -> Aside -> Codex plain `.jsonl` -> Grok -> Antigravity.
3. Compressed Codex files: when a plain rollout the index already holds turns into `.zst` with the same name, keep its rows (same request keys) instead of reading it again. Only files compressed before the widget ever saw them need a decoder; until one exists they stay with the Node collector, and the source says "older compressed records not collected" instead of reporting complete.
4. Trigger: the widget already watches login files; add watchers on the log folders with a debounce (for example 30 s) and a hard minimum interval, plus one catch-up run at start.
5. Measure the whole program (widget + collection) for a day before switching the default.

## Not decided yet

- A managed zstd decoder (a single-file port would be about 1,500 lines). Only worth it if backfill without Node matters.
- Whether a full rebuild (after a rule change) should run in the widget at all. It read about 11 GB here and needs more than one 240 s budget run; it can stay a manual Node step.
