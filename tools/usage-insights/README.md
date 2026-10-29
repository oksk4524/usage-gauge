# UsageGauge Insights

## 한국어

Windows .NET Framework 4.8용 읽기 전용 CLI와 표준입출력 MCP입니다. 실행 파일 하나와 시작할 때 지정한 스냅샷 파일만 필요합니다. 실행 시 Node, 외부 패키지, 설치 과정, 네트워크 연결이 필요하지 않습니다.

### 빌드와 테스트

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
# 개발 테스트 전용. Node 26 사용 가능 환경에서만 실행합니다.
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -Test
```

### CLI

```powershell
.\UsageInsights.exe summary --snapshot C:\data\usage.snapshot.json --period 7d --json
.\UsageInsights.exe breakdown --snapshot C:\data\usage.snapshot.json --period30d --provider claude --dataset claude_cli_local --by project --limit 10 --json
.\UsageInsights.exe limits --snapshot C:\data\usage.snapshot.json --provider codex --json
.\UsageInsights.exe diagnostics --snapshot C:\data\usage.snapshot.json --json
.\UsageInsights.exe habits --snapshot C:\data\usage.snapshot.json --period all --json
.\UsageInsights.exe costs --snapshot C:\data\usage.snapshot.json --json
```

명령은 `summary`, `breakdown`, `limits`, `diagnostics`, `habits`, `costs`입니다. 기간은 `7d`, `30d`, `all`이며 기본값은 `7d`입니다. `--period7d`, `--period30d`, `--periodall`도 지원합니다. 기간 끝은 현재 시간이 아니라 스냅샷의 `period.to`입니다. 7일·30일은 저장된 자료가 더 짧아도 각각 정확히 7일·30일을 조회하며, 앞쪽에 없는 날짜는 미확인으로 셉니다. 출력은 항상 기계가 읽을 수 있는 JSON입니다. `--json`을 생략하면 표준 오류에 간단한 안내가 추가됩니다. 성공 종료 코드는 0, 검증 오류는 2입니다.

`--by`는 `--dimension` 별칭도 지원하며 breakdown 전용입니다. project/session/model/attribution을 지원합니다. `--limit`은 기본 10, 범위 1..50입니다. `limits`는 계정 범위라 dataset 필터를 지원하지 않습니다. `costs`는 출처별 비용 구조가 정의되지 않아 provider/dataset 필터를 지원하지 않습니다. 지원하지 않는 조합은 오류이며 조용히 무시하지 않습니다.

### MCP 실행

```powershell
.\UsageInsights.exe --mcp --snapshot C:\data\usage.snapshot.json
```

MCP 클라이언트의 실행 명령에 exe 절대 경로를 넣고 인수에 `--mcp`, `--snapshot`, 스냅샷 절대 경로를 넣습니다. 파일 경로는 시작 설정에만 있으며 도구 스키마에는 없습니다. 입력을 닫으면 종료합니다. 표준 출력은 줄바꿈으로 구분한 JSON-RPC만 사용하고 로그는 표준 오류로 보냅니다.

지원 프로토콜은 정확히 `2026-07-28`, `2025-11-25`, `2025-06-18`입니다. 모든 MCP 클라이언트와의 호환성을 보장하지 않습니다. 최신 방식은 initialize 없이 요청마다 `params._meta`에 아래 3개 항목을 전달해야 합니다.

```json
{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"example","version":"1"},"io.modelcontextprotocol/clientCapabilities":{}}}}
```

최신 응답은 `resultType: "complete"`를 포함합니다. 구형 방식은 해당 버전의 initialize 요청과 `notifications/initialized` 알림 후 tools/list 및 tools/call을 사용합니다. tools/call은 JSON 텍스트와 structuredContent를 함께 반환합니다. 도구는 6개 CLI 명령과 이름이 같습니다. 알림에는 응답하지 않습니다. 미지원 버전은 -32022와 지원 버전 목록을 반환합니다.

### 해석과 보안

- 원본 공급자 로그, 자격 증명, 사용자 경로 검색, 외부 CLI 실행, 갱신 기능이 없습니다.
- 스냅샷은 시작할 때 한 번 읽습니다. 변경된 파일을 받으려면 이 소비자 프로세스를 다시 시작해야 합니다. 실행 중 다른 경로를 읽지 않습니다.
- 공급자, 계정 범위, 기기 범위, CLI와 Aside는 각각 별도 데이터셋입니다. 자동 합산하거나 출처 간 순위를 만들지 않습니다.
- 누락된 날짜가 있으면 summary.totals는 null입니다. 실제 관측된 날짜의 합은 observedTotals로 따로 제공합니다. null 필드가 포함된 합은 null입니다.
- breakdown은 날짜별 모든 count 필드가 일별 합과 일치할 때만 지원 상태입니다. 상위 행, 나머지 합, 전체 합을 따로 제공합니다. 데이터가 없거나 합이 맞지 않으면 unsupported입니다.
- limits는 현재 관측값입니다. 비교는 공급자, 출처, 모델이 같은 percent 창에 한정합니다. 크레딧과 퍼센트는 비교하지 않습니다. 잔여 시간 예측이 아닙니다.
- habits는 기록된 이벤트 시간대와 관측된 상위 5개 날짜입니다. 실제 근무시간, 수면, 생산성 또는 절감 효과가 아닙니다.
- 출처의 의미, 수집 시각, 스냅샷 시각, 나이(초)를 제공합니다. 미래 시각이면 나이가 음수여서 시계 이상을 숨기지 않습니다.
- 프로젝트와 세션 이름 및 ID는 입력이 이미 마스킹되었다고 주장해도 다시 해시로 마스킹합니다. 알 수 없는 모델, 출처, 의미 코드도 불투명 식별자로 바꿉니다. 기존 마스킹보다 보수적인 정보 손실이 있을 수 있습니다.
- SHA-256 앞 16자리의 결정적 별칭은 익명성 보장이 아닙니다. 작은 사전 후보가 있는 이름은 추측 가능하며 동일 ID는 연결될 수 있습니다. 클라우드 AI가 반환 집계를 받을 수 있습니다.
- 알려진 공급자와 소문자 영문으로 시작하는 영문 소문자, 숫자, 밑줄 64자 이내의 기술적 데이터셋 ID를 그대로 표시합니다. 나머지 데이터셋은 dataset_ 접두 별칭을 사용하므로 출력된 ID로 필터링합니다. 수집기는 기술적 ID에 개인 이름을 넣지 않아야 합니다. `aside`와 `aside_local`, 공급자별 Aside 데이터셋을 지원합니다.
- 임의 JSON 필드, 자유서술 이유, 원본 diagnostics와 capabilities는 그대로 돌려주지 않습니다. diagnostics는 검증된 coverage와 안전한 미지원 목록을 제공합니다. 출처별 자유형 진단은 의도적으로 생략합니다.
- 계약에 통화와 단위가 명확한 비-null 비용 구조가 없으므로 비용은 unavailable이며 비-null 비용을 받으면 UNSUPPORTED_COST_VALUE_SCHEMA를 표시합니다. 절감액을 추정하지 않습니다.
- 최대 스냅샷 16 MiB, 최대 입력 줄 65,536자, 최대 출력 2,097,152자, 최대 데이터셋 64개, 최대 기간 3,661일입니다. 초과 입력은 다음 줄부터 복구합니다. 긴 요청 취소는 구현하지 않으며 모든 요청은 짧은 동기식 메모리 조회입니다.
- 2^53-1보다 큰 정수, 음수 사용량, 소수 토큰, 잘못된 범위와 스키마는 거부합니다. 오류에는 입력 내용이나 파일 경로를 포함하지 않습니다.

### 검증 범위

`tests.cjs`는 합성 스냅샷을 고유한 임시 .fixture 파일에 생성하고 종료 시 삭제합니다. 실제 데이터 파일을 수정하지 않습니다. 명령, 마스킹, null, 범위, 현재 프로토콜, 구형 2개 버전, 잘못된 입력과 긴 줄, 미지원 도구와 파일 인수, 누락된 스냅샷, 잘못된 정수와 스키마를 검사합니다. 실제 상용 MCP 클라이언트 연결 검증과 사용자 원본 데이터 대조는 별도입니다.

## English

A standalone read-only CLI and stdio MCP consumer for Windows .NET Framework 4.8. Build with the inbox csc compiler and System.Web.Extensions. No packages or Node runtime are needed by the executable. Node is used only by the isolated developer test runner.

Run `build.ps1` to compile; run `build.ps1 -Test` to compile and execute synthetic tests. Use the examples above. `--snapshot` is mandatory startup configuration. The snapshot is read once and projected onto a strict output allowlist. No provider files, credentials, network, scans, child processes, refresh, or mutation functionality exists.

Commands are summary, breakdown, limits, diagnostics, habits, costs. Periods 7d/30d/all end at snapshot.period.to, not the wall clock. Output is JSON, even without --json; that flag suppresses the stderr human notice. Dataset/source scopes remain separate. Missing selected days produce null totals and separate observedTotals, not zero filling. Breakdown is accepted only when all count fields reconcile by day; results include exact remainder and total. Limits compare percent windows only within the same provider, source and model. Event distributions are not working hours or productivity.

MCP supports exactly 2026-07-28 (per-request metadata, server/discover and resultType complete), 2025-11-25 and 2025-06-18 (initialize and initialized notification). It does not claim universal client compatibility. Every modern request must include protocolVersion, clientInfo and clientCapabilities in params._meta with the io.modelcontextprotocol/ prefix. Six read-only tools return structuredContent plus serialized JSON text. File paths are absent from tool schemas. Newline-delimited UTF-8 JSON-RPC is the only stdout output in MCP mode. EOF exits. Diagnostics use stderr.

Privacy is conservative: arbitrary fields and free-form source diagnostics are discarded; project/session identifiers and labels are always re-masked. Unknown source/model/semantic strings become deterministic opaque hashes. This is pseudonymization, not guaranteed anonymity. Cloud clients may receive aggregates. Cost values with an unspecified currency/value schema are explicitly unsupported rather than guessed. Unknown values remain null.

Bounds: 16 MiB snapshot, 65,536-character request line, 2,097,152-character response, 64 datasets and 3,661 calendar dates. Integer counts must fit 0..2^53-1. Tokens cannot be fractional. Requests run synchronously; asynchronous cancellation, subscriptions, resources, prompts, HTTP and extensions are not implemented. tools/list has no pagination because the six tools fit one bounded response. Unknown commands/options and unsupported filters fail explicitly. Error messages never include source text or paths.

Tests use synthetic temporary fixtures only and clean them up. Production widget/server operation, provider collection and real-client interoperability are outside this component's test scope.

Protocol references inspected: https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning , https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio , https://modelcontextprotocol.io/specification/2026-07-28/server/discover , https://modelcontextprotocol.io/specification/2026-07-28/server/tools .

Model allowlist note: gemini-weekly, gemini-5h, 3p-weekly, 3p-5h and gemini-argon-wtu-weekly are quota bucket names reported by the original Antigravity /usage response (source antigravity_cli_usage), not real model names. The contract has no pool field, so they are carried in the model string. Fixed collector diagnostic codes are allowlisted so they stay readable; unknown strings are still hashed. totalRule reported_total/total_tokens means the original source reported the total and its component definition is unverified.
