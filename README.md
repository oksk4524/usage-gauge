# UsageGauge

A tiny Windows taskbar widget showing how much of your **weekly** quota is left for
Codex, Claude, Grok and Antigravity (Gemini, Claude/GPT).

![widget](docs/widget.png)
![widget on a light taskbar](docs/widget-light.png)

- Ring gauges on the taskbar with time left until each weekly reset; hover for exact times.
- Shows only services set up on your PC (hide any via right-click). Hides over fullscreen apps.
- ~30 MB RAM, well under 1% CPU, one ~70 KB executable. No other tools needed.
- Light/dark taskbars, display scaling (read at start-up), English/Korean (follows Windows; override via right-click).

## Install

Windows 10/11; the C# compiler built into Windows is enough.

```powershell
git clone https://github.com/oksk4524/usage-gauge
cd usage-gauge
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Autostart
```

No git? **Code > Download ZIP**, unzip, run the last line there. Uninstall: same line with `-Uninstall`.
Drag to move; right-click for refresh, language, gauges, quit.

## How it works

| Gauge | Source | Login read from |
|---|---|---|
| Codex | `chatgpt.com/backend-api/wham/usage` | `~/.codex/auth.json` |
| Claude | `api.anthropic.com/api/oauth/usage` | `~/.claude/.credentials.json` (Claude Code) |
| Grok | `cli-chat-proxy.grok.com/v1/billing` | `~/.grok/auth.json` |
| Antigravity | `agy -p /usage --output-format json` | agy's own login |

Polled every 5 min (Antigravity 15 min), paused while you're away. These are the official tools' internal
endpoints, not public APIs, and may change. On failure a gauge keeps its last value with an amber dot; the reason
goes to `%LOCALAPPDATA%\UsageGauge\error.log` (paste it into an issue).

**Logins are only read**, never logged or sent anywhere but the service itself. Expired logins are renewed by
using the official tool (Codex ~10 days, Claude/Grok a few hours); until then the gauge shows its last value.
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

## 한국어

작업표시줄에 Codex·Claude·Grok·Antigravity의 **주간** 남은 사용량을 띄우는 위젯이에요.

![widget-ko](docs/widget-ko.png)

- 각 공식 도구가 PC에 저장한 로그인을 **읽기만** 해요. 로그인된 서비스만 칸이 나와요.
- 로그인이 만료되면 공식 도구를 다시 쓸 때까지 마지막 값을 보여줘요. 우클릭 "로그인 자동 갱신(실험적)"을 켜면 위젯이 대신 갱신해요(기본 꺼짐).
- 주황 점: 값이 오래됐거나 갱신이 계속 실패하는 중. 원인은 `%LOCALAPPDATA%\UsageGauge\error.log`.
- 설치는 위 Install 명령 그대로, 삭제는 `-Uninstall`.

## Credits & license

Inspired by [CodexBar](https://github.com/steipete/CodexBar) / [Win-CodexBar](https://github.com/nesszer/Win-CodexBar);
icons from Win-CodexBar and [lobe-icons](https://github.com/lobehub/lobe-icons) (see [NOTICE](NOTICE)).
Product names and logos belong to OpenAI, Anthropic, xAI and Google; this project isn't affiliated with them. MIT.
