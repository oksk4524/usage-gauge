# UsageGauge 미리보기 문구 검토

## 범위

자주 보는 사용량 화면은 짧게, 출처의 한계와 AI 공유 안내는 필요한 조건을 풀어서 썼습니다. 기존 CSS와 Pretendard 굵기 위계, 사이드 메뉴, 서비스 탭, 그래프 및 계정 한도 패널을 재사용합니다. 제작 범위는 이 디렉터리뿐이며 운영 위젯, 수집기, 계정, 설치 상태는 변경하지 않습니다.

## 바뀐 문구

- 이번 확인 / 조회 완료 → 확인 상태 / Last checked. 실제 수집 시각을 표시하고 실시간 조회처럼 표현하지 않습니다.
- 누적 → 선택 기간의 확인된 합계 / Recorded total in selected period. 일부 기록만 존재해도 전체 사용량이라고 단정하지 않습니다.
- 최신 기록일 / Latest recorded day를 그래프 밖에 정확한 정수로 표시합니다.
- 수집 상태 / Sources에서 파일 생성 시각, 출처 수집 시각, 마지막 이벤트, 완료된 마지막 날짜를 구분합니다.
- 누락 / Missing, 확인 불가 / Unavailable, 기록된 0을 구분합니다.
- 근무 시간 등의 추정 대신 시간대별 토큰 이벤트 / Token events by hour를 사용합니다.
- 분석 / Insights는 별도 메뉴이며 프로젝트와 세션 이름은 빌드 단계에서 마스킹합니다.
- AI 연결 안내 / AI access는 읽기 전용 설명입니다. 설치, 연결, 실행 버튼은 없습니다. 클라우드 AI에 집계값이 전달될 수 있다고 알립니다.
- 한국어는 만과 억, 영어는 K/M/B를 사용하며 원시 숫자는 툴팁, 일별 표와 최신 기록일에서 확인할 수 있습니다.
- 모든 중간점 구분자는 제거했습니다. 원문 라이선스와 CLI 명령, 서비스명, 모델명은 번역하지 않습니다.

## 실행

```powershell
node tools\usage-details-preview\builder.cjs INPUT_BASE_HTML INPUT_SNAPSHOT OUTPUT_HTML
node tools\usage-details-preview\check.cjs INPUT_BASE_HTML
```

Node 내장 모듈만 사용합니다. builder.cjs, core.cjs, client.cjs는 같은 디렉터리에 둬야 합니다. 생성된 HTML은 단일 파일이며 네트워크 요청을 금지합니다. 기존 HTML의 내장 로고, CSS, 원문 라이선스를 읽고 기존 스크립트는 실행하거나 복사하지 않습니다.

## 검사와 한계

check.cjs는 누락과 0, 기간 기준, 비교 조건, 출처 분리, 마스킹, 단일 스크립트, 외부 의존성, 한국어/영어 렌더와 메뉴 및 다이얼로그 이벤트를 검사합니다. 테스트 숫자는 메모리 내 합성 fixture에만 존재하며 산출 HTML에 섞이지 않습니다.

브라우저에서의 실제 픽셀, 줄바꿈, 키보드 포커스 이동 검사는 부모 작업에서 필요합니다. 이 작업에서는 브라우저 UI를 조작하지 않았습니다. Pretendard는 기존 파일처럼 설치된 로컬 서체가 있을 때 사용하며 새 서체 파일이나 CDN은 추가하지 않습니다. 62일 초과 그래프는 월별로 묶고 정확한 일별 값은 표에 남깁니다. 비교는 comparisonSafe뿐 아니라 두 기간 모두 observed이고 latestCompleteDate 이내인 경우에만 허용하므로 보수적으로 숨겨질 수 있습니다. 원인 코드가 추가돼도 개인정보나 미번역 원문을 노출하지 않도록 화면은 범주형 안내를 사용하고 상세 진단은 읽기 전용 CLI로 안내합니다.

## 2026-10-29 보완

- 한도 카드는 선택한 서비스의 한도만 표시합니다. 다른 계정은 서비스 탭으로 고릅니다.
- source=aside_turns 또는 id=aside_unattributed는 Aside 복구 요약 / Recovered Aside summaries로 표시하고, 모델 귀속 미확인, 턴 종료일 묶음, 시간대 분석 미제공, 다른 출처와 중복 미확인을 상세 모달에서 한영으로 안내합니다. missing_aside_session_files, unmetered_records도 사용자 문장으로 안내하며 원인 코드는 화면에 노출하지 않습니다.
- 분석 표는 상위 10개와 나머지 합계만 보이고 전체 항목은 접는 영역에 있습니다. 상위 10개와 나머지의 합이 분류 합계와 같을 때만 일치 표시를 합니다.
- 전체 기간은 선택 dataset.days의 최초일부터이며 데이터가 없으면 snapshot.period.from을 씁니다. 7일과 30일은 snapshot.period.to 기준입니다. core.bounds(period, dataset)를 days, groups, compare, 날짜 캡션, 시간대 분석이 함께 씁니다.
- 토큰 세부 칩은 축약값을 보이고 title에 정확한 값을 둡니다. 메인 집계 규칙은 한 줄이며 자세한 규칙은 기존 모달을 씁니다.
- 실제 JSON 연결은 부모 작업에서 합니다. 이 변경은 합성 fixture로만 검사했습니다.

