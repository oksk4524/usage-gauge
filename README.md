# UsageGauge

Shows your remaining weekly quota for Claude Code, Codex, Grok and Antigravity on the Windows taskbar, with a countdown to each reset.

**[Download for Windows](https://github.com/oksk4524/usage-gauge/releases/latest/download/UsageGauge-Setup.exe)**

Windows 10/11. Free and open source. Written in C#; no Electron runtime.

![UsageGauge on a dark taskbar](docs/widget.png)

Drag to move it. Right-click to choose which services to show, change the language or turn off startup with Windows.

## Install

1. Sign in to at least one supported tool on this PC: Codex CLI, Claude Code, Grok CLI or Antigravity CLI (`agy`).
2. Download and run **UsageGauge-Setup.exe**, then confirm installation.
3. The widget appears next to the taskbar clock.

Browser-only ChatGPT or Claude logins are not supported. You do not need a separate UsageGauge account.

The installer is **unsigned**, so Windows or antivirus software may warn. Check the [release](https://github.com/oksk4524/usage-gauge/releases/latest) and its SHA-256 before running it. Do not disable antivirus.

It starts with Windows by default. Reopen it from the Start menu after quitting, or remove it through **Settings > Apps > UsageGauge**.

[Setup and troubleshooting](docs/QUICKSTART.md)

## Reading the gauges

The percentage is **quota remaining**, not quota used. 100% means the full weekly quota is still available. Hover for the exact reset time.

An amber dot means the reading is stale after a failed refresh. The displayed number is the last successful reading, not necessarily the current balance.

Codex, Claude and Grok refresh every five minutes; Antigravity every fifteen. Refreshes pause while you are away.

## Credentials

UsageGauge reads the login files saved by the supported tools and sends authenticated requests directly to each service. It has no telemetry or collection server.

Login files are read-only by default. If you enable experimental Claude/Grok renewal, it writes refreshed tokens back to those tools' login files. That option is off by default.

This is an unofficial tool. Provider changes can break readings, and CLI quotas may differ from website or app quotas. The Gemini gauge reads Antigravity's pool, not the Gemini web app limit.

<details>
<summary>More screenshots</summary>

Light taskbar:

![UsageGauge on a light taskbar](docs/widget-light.png)

Korean:

![UsageGauge in Korean](docs/widget-ko.png)

Screenshots were captured from earlier builds. Their numbers are examples, not live readings.

</details>

<details>
<summary>Build from source</summary>

Windows' built-in .NET Framework C# compiler is used; no Electron or Node.js runtime.

```powershell
git clone https://github.com/oksk4524/usage-gauge
cd usage-gauge
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Autostart
```

Without git: **Code > Download ZIP**, extract, then run the last command in that folder.
To remove a source installation, run the same command with `-Uninstall` instead of `-Autostart`.
To build the single-file installer without installing it:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Package
```

Output: `dist\UsageGauge-Setup.exe`. Logos, LICENSE and NOTICE are embedded.

</details>

<details>
<summary>Technical details and limitations</summary>

## How it works

| Gauge | Source | Login read from |
|---|---|---|
| Codex | `chatgpt.com/backend-api/wham/usage` | `~/.codex/auth.json` |
| Claude | `api.anthropic.com/api/oauth/usage` | `~/.claude/.credentials.json` (Claude Code) |
| Grok | `cli-chat-proxy.grok.com/v1/billing` | `~/.grok/auth.json` |
| Antigravity | `agy -p /usage --output-format json` | agy's own login |

Polled every 5 min (Antigravity 15 min), paused while you're away. These are the official tools' internal
endpoints, not public APIs, and may change. On failure a gauge keeps its last value with an amber dot; the reason
goes to `%LOCALAPPDATA%\UsageGauge\error.log` (review and redact personal information before sharing it in an issue).

**By default, credentials are read without being changed.** They are sent only to the corresponding service for authenticated requests, not to a UsageGauge server, and are never logged. When a login expires, sign in again through the official tool. Until then, the gauge shows its last value and says
*sign in*: click it to open that tool's own sign-in (`codex login`, `claude auth login`, `grok login`) in a terminal.
Optional *Renew Claude/Grok logins* (right-click, off by default) renews them itself: it re-reads first, skips if
the file is busy or the tool already saved a newer login, and patches only the three token values in place.
Remaining risk: if Claude Code or grok renews at the very same moment, it may ask you to sign in again.

## Known limitations

- Codex logins kept in the OS keyring (`cli_auth_credentials_store = "keyring"`/`"auto"`) aren't read; nor is a Claude Code login kept anywhere but `~/.claude/.credentials.json`.
- Several Grok accounts in `auth.json`: the Grok gauge stays off (can't tell which is active).
- `agy` installed but not signed in: the Antigravity gauges show an error.
- Scaling is read at start-up: after changing it, or moving the widget to a monitor with different scaling, restart the widget.
- Some antivirus tools flag unsigned programs that read login files and use the network. The whole source is
  `UsageGauge.cs`; `install.ps1` builds it on your PC.
- Unofficial; use at your own risk. Test overrides: `USAGEGAUGE_SCALE` (e.g. `1.5`), `USAGEGAUGE_THEME` (`light`/`dark`).

</details>

## Credits & license

Inspired by [CodexBar](https://github.com/steipete/CodexBar) / [Win-CodexBar](https://github.com/nesszer/Win-CodexBar);
icons from Win-CodexBar and [lobe-icons](https://github.com/lobehub/lobe-icons) (see [NOTICE](NOTICE)).
Product names and logos belong to OpenAI, Anthropic, xAI and Google; this project isn't affiliated with them. MIT.
