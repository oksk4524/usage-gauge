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

To share it as one file, `install.ps1 -Package` builds `dist\UsageGauge-Setup.exe`: double-clicking it installs
(start with Windows and a Start menu entry included), and it is removed from **Settings > Apps**. It is unsigned, so Windows SmartScreen
warns on first run (*More info > Run anyway*).
Drag to move. Right-click for refresh, gauges, language, start with Windows, reset position and the error log.

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
using the official tool (Codex ~10 days, Claude/Grok a few hours); until then the gauge shows its last value and says
*sign in*: click it to open that tool's own sign-in (`codex login`, `claude auth login`, `grok login`) in a terminal.
Direct login renewal has been removed to avoid racing the official tools and overwriting newer credentials.
The widget never sends OAuth refresh POSTs or writes/deletes provider login files. A legacy renew-logins.txt
setting is left untouched but no longer enables renewal. On HTTP 401 it re-reads the login and retries only
when the official tool has already supplied a different access token. Antigravity runs the official CLI,
whose own authentication behavior is controlled by that CLI.

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
- 로그인이 만료되면 마지막 값과 함께 "로그인 만료"가 떠요. 누르면 공식 도구의 로그인 창이 열려요. 위젯의 직접 인증 갱신·파일 쓰기는 동시 저장 충돌을 막기 위해 제거했어요. 이전 자동 갱신 설정 파일은 지우거나 바꾸지 않지만 더는 사용하지 않아요.
- 주황 점: 값이 오래됐거나 갱신이 계속 실패하는 중. 원인은 `%LOCALAPPDATA%\UsageGauge\error.log`.
- 우클릭 메뉴: 새로고침, 표시할 항목, 언어, Windows 시작 시 자동 실행, 위치 초기화, 오류 기록 보기.
- 설치는 위 Install 명령 그대로, 삭제는 `-Uninstall`.
- 다른 사람에게 줄 때: `install.ps1 -Package`로 만든 `dist\UsageGauge-Setup.exe` 하나만 주면 돼요. 더블클릭하면 설치되고, 설정 > 앱에서 지울 수 있어요. 서명이 없어서 처음 실행할 때 Windows가 경고해요(추가 정보 > 실행).

## Credits & license

Inspired by [CodexBar](https://github.com/steipete/CodexBar) / [Win-CodexBar](https://github.com/nesszer/Win-CodexBar);
current service logos come from official sites or official press kits, checked on 2026-10-29. OpenAI and Claude use transparent official symbols rasterized from preserved SVG originals with normalized transparent padding; the other logos retain original PNG bytes (see [source records](assets/service-logos.json) and [NOTICE](NOTICE)).
Product names and logos belong to OpenAI, Anthropic, xAI, Google and Aside Computer Inc.; this project isn't affiliated with them. MIT.
