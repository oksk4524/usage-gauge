# UsageGauge

**남은 AI 사용량과 리셋 시간, 작업표시줄에서 바로.**

Claude Code · Codex · Grok · Antigravity 사용량을 확인하려고 창을 오가지 마세요.
작업하던 화면 그대로, 얼마나 남았는지 한눈에 볼 수 있어요.

![UsageGauge 한국어 사용 화면](docs/widget-ko.png)

### [Windows 설치파일 다운로드](https://github.com/oksk4524/usage-gauge/releases/latest/download/UsageGauge-Setup.exe)

무료 · 오픈소스 · Windows 10/11 · 별도 UsageGauge 계정 불필요

- **지금 얼마나 더 쓸 수 있는지.** 서비스별 주간 **남은 비율**을 보여줘요.
- **다시 채워질 때까지 얼마나 남았는지.** 리셋까지 남은 시간을 함께 보여줘요.
- **필요한 도구만, 늘 보이는 자리에.** 이 PC에 설정된 서비스만 표시하고, 드래그로 위치를 옮길 수 있어요.

## 설치하고 바로 보기

1. 위 설치파일을 받아 실행하고 설치에 동의하세요.
2. 시계 옆에 나타나는 위젯에서 남은 사용량을 확인하세요.
3. 표시 항목·언어·자동 실행은 위젯 **우클릭**으로 바꿀 수 있어요.

**먼저 알아둘 점:** 지원 도구 중 하나 이상이 이 PC에 설치·로그인되어 있어야 해요. ChatGPT·Claude 웹사이트 로그인만으로는 표시되지 않아요.

설치파일은 아직 코드 서명이 없어 Windows 보안 경고가 나올 수 있어요. 출처와 [릴리스의 SHA-256](https://github.com/oksk4524/usage-gauge/releases/latest)을 확인하고, 신뢰하는 경우에만 실행하세요. 백신을 끄지 마세요.

시작할 때 자동 실행되며, 삭제는 **설정 > 앱 > UsageGauge**에서 할 수 있어요.
[처음 설정하기 · 자주 묻는 질문](docs/QUICKSTART.md)

## 로그인 정보는 어떻게 쓰나요?

기존 도구의 로그인 정보로 **해당 서비스에 직접** 사용량을 조회해요. UsageGauge 수집 서버나 사용 추적은 없어요.
기본 설정에서는 로그인 파일을 읽기만 해요. **실험적 Claude/Grok 자동 갱신을 직접 켠 경우에만** 새 토큰을 로그인 파일에 저장해요.

공식 앱이 아닌 개인 오픈소스 도구예요. 서비스 변경으로 조회가 중단될 수 있고, 웹·앱·CLI의 한도가 서로 다를 수 있어요.
위 화면은 기존 버전에서 캡처한 예시이며, 내 계정의 수치나 현재 상태를 뜻하지 않아요.

## English

**Your AI quota and reset countdown. Right on your Windows taskbar.**

Stop switching windows just to check how much Claude Code, Codex, Grok or Antigravity quota you have left.
Keep the numbers in sight while you work.

![UsageGauge on a dark taskbar](docs/widget.png)
![UsageGauge on a light taskbar](docs/widget-light.png)

**[Download for Windows](https://github.com/oksk4524/usage-gauge/releases/latest/download/UsageGauge-Setup.exe)** · Free · Open source · Windows 10/11

- See your **weekly quota remaining**, not quota used, plus time until reset.
- Show only the services set up on your PC. Drag to move; right-click to customize.
- Uses your existing tool logins. No UsageGauge account, telemetry or collection server.

Download, run and confirm installation. Starts with Windows; uninstall from **Settings > Apps**.
At least one supported tool must already be installed and signed in locally. Website-only ChatGPT/Claude logins are not supported.
The installer is **unsigned**: Windows or antivirus may warn. Verify the release and SHA-256 before deciding to run it. Do not disable antivirus.
Credentials are read-only by default; optional Claude/Grok renewal writes refreshed tokens back only when enabled.
Screenshots are previously captured examples, not live account data. Unofficial tool; provider changes may interrupt readings.

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

**By default, credentials are read without being changed.** They are sent only to the corresponding service for authenticated requests, not to a UsageGauge server, and are never logged. Expired logins are renewed by
using the official tool (Codex ~10 days, Claude/Grok a few hours); until then the gauge shows its last value and says
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
