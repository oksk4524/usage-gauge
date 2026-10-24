# UsageGauge

A tiny Windows taskbar widget that shows how much of your **weekly** quota is left for
Codex, Claude, Grok and Antigravity (Gemini, and Claude/GPT inside Antigravity).

![widget](docs/widget.png)

- Glass ring gauges docked on the taskbar, with time left until each weekly reset.
- Hides instantly over fullscreen apps, stays above the taskbar.
- About 30 MB RAM and well under 1% of one CPU core. One ~60 KB executable, no runtime to install.
- No third-party helper: it reads usage straight from each service with the login the official tool already saved on your PC.

## Where the numbers come from

| Gauge | Source | Login it uses |
|---|---|---|
| Codex | `chatgpt.com/backend-api/wham/usage` | `~/.codex/auth.json` (Codex CLI / app) |
| Claude | `api.anthropic.com/api/oauth/usage` | `~/.claude/.credentials.json` (Claude Code) |
| Grok | `cli-chat-proxy.grok.com/v1/billing` | `~/.grok/auth.json` (Grok CLI) |
| Gemini, Claude·GPT (Antigravity) | `agy -p /usage --output-format json` | Antigravity CLI's own login |

Codex, Claude and Grok are polled every 5 minutes; Antigravity every 15 minutes, because it
starts the `agy` CLI. Polling pauses while the PC is unattended and resumes when you come back.

These are the same internal endpoints the official tools use. They are not public APIs and can change.
When something breaks, the gauge keeps the last good number and shows an amber dot, and the reason
is written to `%LOCALAPPDATA%\UsageGauge\error.log`.

### Token refresh

- **Codex**: read-only. The Codex CLI/app refreshes its own login.
- **Claude, Grok**: if the saved token has been expired for more than two minutes (so the official tool
  had its chance first) or the server rejects it, the widget refreshes it with the official OAuth endpoint
  and writes it back atomically, leaving every other field untouched. Tokens are never logged or sent
  anywhere except the service's own API.

## Install

Requires Windows 10/11. The C# compiler that ships with Windows is enough.

```powershell
git clone https://github.com/oksk4524/usage-gauge
cd usage-gauge
.\install.ps1 -Autostart
```

Drag the widget to move it (the position is remembered). Right-click for refresh / quit.
Hover for exact reset times.

## Credits

- Idea and endpoint research: [CodexBar](https://github.com/steipete/CodexBar) and
  [Win-CodexBar](https://github.com/nesszer/Win-CodexBar) (MIT).
- Icons: Codex and Claude marks from Win-CodexBar; Grok, Gemini and Antigravity marks from
  [lobehub/lobe-icons](https://github.com/lobehub/lobe-icons) (MIT).

All product names and logos are trademarks of their respective owners (OpenAI, Anthropic, xAI, Google).
This project is not affiliated with any of them.

## License

MIT
