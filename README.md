# UsageGauge

A tiny Windows taskbar widget that shows how much of your **weekly** quota is left for
Codex, Claude, Grok and Antigravity (Gemini, and Claude/GPT inside Antigravity).

![widget](docs/widget.png)

![widget on a light taskbar](docs/widget-light.png)

- Glass ring gauges docked on the taskbar, with time left until each weekly reset.
- Hides instantly over fullscreen apps, stays above the taskbar.
- About 30 MB RAM and well under 1% of one CPU core. One ~60 KB executable, no runtime to install.
- No third-party helper: it reads usage straight from each service with the login the official tool already saved on your PC.
- Only shows the services you actually use (a gauge appears when that tool's login is on your PC); hide any of them from the right-click menu.
- Follows display scaling (100-300%) and light/dark taskbars.
- English or Korean, following the Windows display language (any other language falls back to English). Override it from the right-click menu.

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
is written (in English) to `%LOCALAPPDATA%\UsageGauge\error.log` - paste it into an issue as is.

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
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Autostart
```

No git? Use **Code > Download ZIP**, unzip, and run the same last line in that folder.

Uninstall: `powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall`

Drag the widget to move it (the position is remembered). Right-click for refresh, language, which gauges to show, and quit.
Hover for exact reset times.

## 한국어

작업표시줄에 Codex, Claude, Grok, Antigravity(Gemini, Claude·GPT)의 **주간** 남은 사용량을 링 게이지로 띄워주는 작은 위젯이에요.

![widget-ko](docs/widget-ko.png)

- 각 서비스 공식 도구가 이 PC에 저장해 둔 로그인으로 사용량을 직접 읽어요. 다른 프로그램이 필요 없어요.
- 전체 화면 앱 위에서는 바로 숨고, 메모리 약 30MB, CPU는 1% 미만이에요.
- 이 PC에 로그인된 서비스만 칸이 나와요. 우클릭 메뉴 "표시할 항목"에서 숨길 수도 있어요.
- 화면 배율(100~300%)과 밝은/어두운 작업표시줄에 맞춰 그려요.
- Windows 표시 언어가 한국어면 한국어로, 그 외에는 영어로 나와요. 우클릭 메뉴에서 바꿀 수 있어요.
- 주황 점: 값이 오래됐거나 갱신이 계속 실패하는 중이라는 뜻이에요. 원인은 `%LOCALAPPDATA%\UsageGauge\error.log`에 남아요.

설치: 저장소를 받은 뒤(또는 Code > Download ZIP) 그 폴더의 PowerShell에서
`powershell -ExecutionPolicy Bypass -File .\install.ps1 -Autostart`  
삭제: 같은 명령에 `-Uninstall`

## Credits

- Idea and endpoint research: [CodexBar](https://github.com/steipete/CodexBar) and
  [Win-CodexBar](https://github.com/nesszer/Win-CodexBar) (MIT).
- Icons: Codex and Claude marks from Win-CodexBar; Grok, Gemini and Antigravity marks from
  [lobehub/lobe-icons](https://github.com/lobehub/lobe-icons) (MIT).

All product names and logos are trademarks of their respective owners (OpenAI, Anthropic, xAI, Google).
This project is not affiliated with any of them.

## License

MIT
