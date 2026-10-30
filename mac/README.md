# UsageGauge 맥 버전

메뉴 막대에 값을 읽은 서비스마다 흑백 로고, 작은 잔량 막대, 남은 숫자(% 없이)를 나란히 보여 줍니다(C안). 지금 쓸 수 있는 서비스가 앞에, 다 쓴 서비스는 흐리게 뒤에 오고, 값을 못 읽은 서비스는 숨깁니다. 숫자는 지금 실제로 막는 한도(주간과 5시간 중 적게 남은 쪽)이고, 마우스를 올리면 "Codex 주간 37% 남음 · Claude 주간 다 씀(2일 16시간 뒤)"처럼 나옵니다. 읽은 한도가 없으면 회색 빈 링입니다. 누르면 링 4개(Codex, Claude, Grok, Gemini/Antigravity)와 초기화 시각, 이 맥 대시보드 기준 "지금 할 일"(있을 때만), "사용량 상세 보기", "AI 진단", 새로고침이 나옵니다. 종료는 아이콘 오른쪽 클릭 메뉴에 있습니다. 화면 확인용으로 `UsageGauge --render-preview <폴더>`가 PNG를 만듭니다.

## 만들기와 시험

```bash
mac/build.sh        # mac/build/UsageGauge.app (Swift 명령줄 도구만 필요, Xcode 프로젝트 없음)
mac/test.sh         # 응답 해석, 401/403, 계정 바뀜, 가리기, 대시보드 전달 형식 시험 (네트워크 없음)
mac/build/UsageGauge.app/Contents/MacOS/UsageGauge --probe   # 한 번 조회해 결과만 출력 (토큰 출력 없음)
```

## 로그인 정보 (읽기만)

| 서비스 | 읽는 곳 |
|-|-|
| Codex | `~/.codex/auth.json` (`CODEX_HOME`) |
| Claude | 키체인 항목 `Claude Code-credentials`, 없으면 `~/.claude/.credentials.json` (`CLAUDE_CONFIG_DIR`) |
| Grok | `~/.grok/auth.json` (`GROK_HOME`) |
| Antigravity | `agy -p /usage` (없으면 "설치 안 됨") |

윈도우 위젯과 같은 규칙입니다. 조회는 GET만 하고, 토큰 갱신 POST나 로그인 정보 쓰기는 하지 않습니다. 401과 403을 구분하고, 로그인 계정이 바뀌면 이전 계정 값은 버립니다. Claude 키체인 항목을 처음 읽을 때 macOS가 허용 창을 띄울 수 있습니다. 허용 창에서 거부하면 "새로고침"을 누를 때까지 다시 묻지 않습니다.

## 사용량 상세 화면 (대시보드)

```bash
mac/install-dashboard.sh --refresh-now   # 코드 복사, 화면 한 번 생성. 자동 실행은 켜지 않음
mac/install-dashboard.sh --activate      # 30분마다 갱신 켜기 (launchd LaunchAgent, 로그인한 사용자만)
mac/install-dashboard.sh --deactivate    # 끄기
mac/install-dashboard.sh --uninstall     # 끄고 대시보드 폴더 삭제
```

저장 위치는 `~/Library/Application Support/UsageGauge`입니다(윈도우의 `%LOCALAPPDATA%\UsageGauge`). 대시보드의 "AI로 진단하기" 링크(`usagegauge://habit-check`)는 앱 Info.plist의 URL scheme으로 받습니다. 앱이 한 번 실행되어야 macOS에 등록됩니다.

## 설치 (사용자가 직접)

빌드한 앱은 개발자 서명과 공증이 없어서, 처음 열 때 macOS 보안 경고가 뜰 수 있습니다. Finder에서 `mac/build/UsageGauge.app`을 응용 프로그램 폴더로 옮기고 열어 주세요. 로그인할 때 자동으로 켜려면 시스템 설정 > 일반 > 로그인 항목에 추가합니다.
