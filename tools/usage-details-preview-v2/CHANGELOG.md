# usage-details-preview-v2 CHANGELOG

New folder only. v1 (`tools/usage-details-preview`), the widget, collector, CLI, MCP and data are untouched. Built as a separate preview artifact and tested in a separate local preview server by the parent. No widget install/restart, merge or push.
Files: `core.cjs`, `client.cjs`, `builder.cjs`, `v2.css` (extra CSS appended after v1 CSS), `check.cjs` (v1 checks kept) and `check-v2.cjs` (new regressions). Run: `node check.cjs [base.html]` (env `USAGE_SNAPSHOT` overrides the real JSON path). Without a base HTML it uses a stub base; the finished artifact HTML has no `const logos` literal, so use the original base HTML for a real build.

## Items 1-16 and where information moved
1. Daily table: all columns always shown (input, cache read, cache creation, output, reasoning, total, status). Each header has a sub-label derived from `semantics` (in total / not in total / in input / in output, not added again) and the header notes the `totalRule` formula. Null shows a dash (not 0).
2. Numeric cells and headers right aligned with tabular numerals; date and status cells left aligned. Date column is sticky.
3. Table dates are short (month/day, year only when the range spans years), nowrap date and number cells, table region is focusable/scrollable with an explicit horizontal-scroll note.
4. A period without records shows a notice instead of a chart: no fake 0/1/1 axis, no bar hint. Offers "30 days to last record" (new period `last30`, core `lastDate`) and "View all". No refresh button. `last30` is never compared.
5. `[hidden]{display:none!important}` fixes the AI view (providers/controls were visible). AI view split into CLI and MCP; commands follow `tools/usage-insights/README.md` (`UsageInsights.exe`, `--mcp --snapshot`), copy buttons with a status message; clipboard failure or missing `navigator` shows a message and selects the text. No permission request. Not executed here.
6. render() restores focus on the same control (id or data-view/provider/period/lang/details/copy/i/recovered). Chart bars: roving tabindex (latest bar first), Left/Right/Home/End, visible focus box (`.hit`), Enter/Space readout.
7. Quota rows: saved values at or below 5% remaining get a warning style and "saved value" note; a note says this is a display marker, not an official threshold. Checked time plus age kept. Each account/model bucket stays its own row.
8. Top bar no longer repeats breadcrumb/title/snapshot time (hidden). Overview and Insights descriptions removed. One controls line shows source, collected time and coverage status. Snapshot generation time moved to Sources, where the four different times are listed as separate labelled rows.
9. SVG width follows the real card width (`#chart-host` measurement, redrawn on resize); 7 days fit on mobile; 30 days scroll with a hint and start at the latest day; legend for observed / partial (dashed) / no record; All view tells the user it is grouped by month.
10. Exact total shown as text with a copy button; folded table of exact part values with what each part contributes. Compact numbers use at most one decimal (none from 100 up).
11. Insights order: peak and comparison, breakdown (default Model), hourly summary (event hours + top 3, no working-hour inference) with the hourly table folded, then the cost/outcome/forecast notice folded. Comparison-unavailable reason folded. Nothing removed.
12. Dialog and Sources: reason count and missing-day count first, notes before the field list. Missing days grouped into ranges, first 3 shown, full list folded. Recovered summary note has a real button (`data-recovered`) that opens the recovered Aside source.
13. Overview 9-row source table replaced by a summary line plus "View all sources". Full table is in Sources (folded "All sources").
14. Mobile: language toggle and theme icon sit in the brand row, topbar hidden from flow, page description and data-scope button hidden, tighter tabs/controls/panel padding so the headline number comes earlier. Needs a real 390x844 browser measurement (not done here).
15. Touch targets 40px or more at 820px and below (period tabs, text buttons, selects, summaries, close). Focus outlines drawn inside scroll containers. Nav, provider tabs, period tabs and language buttons keep their different shapes.
16. Renames: "Missing dates" is now "Dates without records"; recovered label is "By turn record date"; quotas title is "Account limits". The detail text keeps "turn end date first, then last message or start".

## Wording notes for the parent
- AI privacy sentence now says "Responses from this query tool contain no ..." instead of a global AI guarantee.
- Dates without time are still formatted as UTC calendar dates; timestamps use the snapshot timezone.
- Strings are shortened only lightly; final UX writing is left to the parent.

## Not done / not verified
- No browser render, screenshot, mobile 390x844 y-position, contrast or real focus-ring check.
- The "5% or lower" marker is an arbitrary display rule; confirm or drop.
- Real clipboard behaviour in file:// pages is not tested; only stubbed.
- Records table keeps 8 columns, so it needs horizontal scroll on narrow screens by design.

## Parent UX and browser pass (2026-10-29)
- UX-Writing skill applied to Korean and English. Frequent views are concise; source limits and AI sharing warnings remain explicit. Clipboard errors do not invent a cause.
- Recorded totals, missing data, unknown models and turn-date recovery wording are consistent. Saved quota values are not presented as live status; the 5% highlight is explicitly a UI rule.
- Daily totals moved immediately after dates so mobile users see actual usage before component details. Cache creation and reasoning remain available with inclusion rules.
- Browser-discovered horizontal overflow from absolutely positioned screen-reader text fixed by positioning its null-value wrapper. Unknown values remain null and are visually shown as a hyphen with an accessible label.
- AI view hides source/period/scope controls. A sharing warning precedes command examples. No commands are executed or MCP servers registered by this preview.
- Mobile 390x844: date rows measured 44.5px, down from about 99px; no page-level horizontal overflow in the checked null-value table or last-record range. Horizontal scrolling remains inside wide tables and 30-day charts.
- Parent preservation check: 225 assertions over 9 sources and 9 limit windows; original preview, snapshot and four v1 source files retain identical SHA-256 fingerprints.
- Browser clipboard success/failure paths were tested with mocks, not by changing the operating-system clipboard. Mobile checks use browser emulation, not a physical phone.
