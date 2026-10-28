# UsageGauge

## Your AI quota, in sight

See the weekly quota you have left in Claude Code, Codex, Grok and Antigravity without opening a terminal to check.

![UsageGauge on the Windows taskbar](docs/widget.png)

**[Download for Windows](https://github.com/oksk4524/usage-gauge/releases/latest/download/UsageGauge-Setup.exe)**

Free and open source. Windows 10/11. Uses your existing local tool logins.

## Check before you switch

When Claude is running low, it helps to know what Codex has left. UsageGauge puts your tools together so you can check them without leaving your work.

Each ring shows **weekly quota remaining**, with the time until it resets. Hover for the exact reset time. You do not need a dashboard or terminal window open just to see where you stand.

## Leave it running

It's genuinely lightweight, so you can keep it on while you work. It sits next to the clock, ready when you want a quick look.

- **About 146 KB** for the Windows installer.
- **Native C# on .NET Framework**, with no Electron or Node.js runtime.
- **Scheduled quota checks**, every five minutes for Codex, Claude and Grok; fifteen for Antigravity.
- **Pauses quota checks after 15 minutes of inactivity.**

Antigravity uses its own CLI for readings, which adds work during those refreshes.

## Make it fit your setup

Drag it where you want it. Right-click to choose the services you see, switch between English and Korean, or change whether it starts with Windows.

![UsageGauge on a light taskbar](docs/widget-light.png)

You only need to set up the tools you actually use. UsageGauge shows services with supported local login files, rather than filling your taskbar with empty gauges.

Screenshots above were captured from earlier builds. The numbers are examples, not live readings.

## No new account

UsageGauge uses the logins your tools have already saved on this PC. Requests go directly to the corresponding service. There is no UsageGauge account, telemetry or collection server.

Login files are read-only by default. Experimental Claude/Grok renewal is optional and off by default; turning it on allows refreshed tokens to be saved back to those tools' login files.

## Install

1. Sign in locally to at least one supported tool: **Codex CLI, Claude Code, Grok CLI or Antigravity CLI (`agy`)**.
2. Download and run **UsageGauge-Setup.exe**, then confirm installation.
3. Look next to the taskbar clock. Drag to move the widget; right-click for settings.

It starts with Windows by default. After quitting, reopen it from the Start menu. Remove it through **Settings > Apps > UsageGauge**.

The installer is **unsigned**, so Windows or antivirus software may warn. Check the [release and SHA-256](https://github.com/oksk4524/usage-gauge/releases/latest) before deciding to run it. Do not disable antivirus.

**[Download for Windows](https://github.com/oksk4524/usage-gauge/releases/latest/download/UsageGauge-Setup.exe)**

[Setup and troubleshooting](docs/QUICKSTART.md)

## Questions

**Will it work with a website login?** No. Browser-only ChatGPT and Claude logins are not supported. A supported local tool login is required.

**Does it show quota used or quota left?** Quota left. 100% means the full weekly quota is still available. These are weekly pools, not a promise that every other rate limit is clear.

**What does an amber dot mean?** The last refresh failed and the reading is stale. The widget keeps the last successful value, which may no longer be current.

**Is the Gemini gauge my Gemini web app limit?** No. It reads Antigravity's Gemini pool. Website, app and CLI quotas can differ.

**Is this official?** No. UsageGauge is an independent open-source project. It uses internal service endpoints, so provider changes can interrupt readings.

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

- Codex logins kept in the OS keyring (`cli_auth_credentials_store = "keyring"`/`"auto"`) aren't read; Claude Code credentials must be available in a local `.credentials.json` file (the default path or `CLAUDE_CONFIG_DIR`).
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
