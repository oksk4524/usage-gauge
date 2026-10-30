// Logic tests for the macOS port: response parsing, 401/403, account change, masking, login files and the
// dashboard feed format. No network, no keychain secrets (the keychain is only checked for an item's existence).
// Run: mac/test.sh   (concatenates Sources/*.swift with this file and runs it with the Swift interpreter)
import Foundation

Log.enabled = false
var passed = 0
func check(_ cond: Bool, _ name: String, file: String = #file, line: Int = #line) {
    if cond { passed += 1; print("PASS " + name) } else { print("FAIL " + name + " (line \(line))"); exit(1) }
}
func data(_ s: String) -> Data { Data(s.utf8) }

// ---- Codex ----
let codexBody = """
{"plan_type":"pro","rate_limit":{"allowed":true,"primary_window":{"used_percent":12.5,"limit_window_seconds":18000,"reset_at":1793400000},
"secondary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_at":1793800000}}}
"""
let c1 = Usage.codexResult(200, data(codexBody))
check(c1.ok && c1.remaining == 60, "codex: weekly window is the 604800s one (60% left)")
check(c1.resetsAt == Date(timeIntervalSince1970: 1793800000), "codex: reset_at (seconds)")
check(c1.extra == "5시간 사용 12.5%", "codex: other window listed as extra")
check(c1.windows.count == 2, "codex: both windows kept for the dashboard")
check(Usage.codexResult(401, nil).error!.hasPrefix("로그인 만료(401)"), "codex: 401 is login expired")
check(Usage.codexResult(403, nil).error!.hasPrefix("접근 거부(403)"), "codex: 403 is access denied")
check(Usage.codexResult(429, nil).transient && Usage.codexResult(0, nil).transient && Usage.codexResult(503, nil).transient, "codex: 429/network/5xx are transient")
check(!Usage.codexResult(404, nil).transient, "codex: 404 is not transient")
check(Usage.codexResult(200, data("{\"x\":1}")).error == "응답 형식이 바뀌었어요", "codex: changed format")
check(Usage.codexResult(200, data("{\"rate_limit\":{\"primary_window\":{\"used_percent\":120,\"limit_window_seconds\":604800}}}")).remaining == 0, "codex: over quota shows 0%")

// ---- Claude ----
let claudeBody = """
{"five_hour":{"utilization":7,"resets_at":"2026-10-30T12:00:00.123456+00:00"},"seven_day":{"utilization":33.3,"resets_at":"2026-11-02T00:00:00Z"},"seven_day_opus":null}
"""
let cl = Usage.claudeResult(Usage.parse(data(claudeBody)), 200, nil, nil)
check(cl.ok && abs(cl.remaining - 66.7) < 0.001, "claude: seven_day utilization -> remaining")
check(cl.resetsAt == ISO8601DateFormatter().date(from: "2026-11-02T00:00:00Z"), "claude: resets_at")
check(cl.extra == "5시간 사용 7%", "claude: five_hour listed, null opus skipped")
let expired = Usage.Login(access: "x", expires: Date(timeIntervalSinceNow: -60))
check(Usage.claudeResult(nil, 401, nil, expired).error!.hasPrefix("토큰 갱신 대기(401)"), "claude: 401 with an expired token waits for the official tool")
check(Usage.claudeResult(nil, 401, nil, Usage.Login(access: "x", expires: Date(timeIntervalSinceNow: 3600))).error!.hasPrefix("로그인 만료(401)"), "claude: 401 with a valid-looking token is login expired")
check(Usage.claudeResult(nil, 403, nil, expired).error!.hasPrefix("접근 거부(403)"), "claude: 403 stays access denied")
check(Usage.claudeResult(nil, -1, nil, nil).error == "로그인 없음", "claude: no login")

// ---- Grok ----
let g1 = Usage.grokResult(Usage.parse(data("{\"config\":{\"currentPeriod\":{\"type\":\"USAGE_PERIOD_TYPE_WEEKLY\",\"end\":\"2026-11-03T00:00:00Z\"}}}")), 200, nil, nil)
check(g1.ok && g1.remaining == 100, "grok: omitted usage means nothing used")
let g2 = Usage.grokResult(Usage.parse(data("{\"config\":{\"creditUsagePercent\":25,\"currentPeriod\":{\"type\":\"USAGE_PERIOD_TYPE_MONTHLY\"}}}")), 200, nil, nil)
check(!g2.ok && g2.error == "주간 기간을 찾지 못했어요", "grok: non-weekly period rejected")

// ---- login files (read only), through the same env overrides as Windows ----
let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("ug-logic-\(getpid())")
try! FileManager.default.createDirectory(atPath: tmp + "/grok", withIntermediateDirectories: true)
try! FileManager.default.createDirectory(atPath: tmp + "/claude", withIntermediateDirectories: true)
setenv("GROK_HOME", tmp + "/grok", 1); setenv("CLAUDE_CONFIG_DIR", tmp + "/claude", 1)
try! data("{\"https://auth.x.ai::a\":{\"key\":\"tok\",\"user_id\":\"u123456789\",\"email\":\"person@example.com\",\"expires_at\":\"2026-11-01T00:00:00Z\"}}").write(to: URL(fileURLWithPath: tmp + "/grok/auth.json"))
let gl = Usage.readGrok()!
check(gl.access == "tok" && gl.accountKey == "grok:u123456789" && gl.account == "person@example.com", "grok: login read from auth.json")
try! data("{\"https://auth.x.ai::a\":{\"key\":\"t1\"},\"https://auth.x.ai::b\":{\"key\":\"t2\"}}").write(to: URL(fileURLWithPath: tmp + "/grok/auth.json"))
check(Usage.readGrok()!.error != nil, "grok: several accounts is an error, not a guess")
let before = try! Data(contentsOf: URL(fileURLWithPath: tmp + "/grok/auth.json"))
_ = Usage.readGrok()
check(try! Data(contentsOf: URL(fileURLWithPath: tmp + "/grok/auth.json")) == before, "grok: auth.json unchanged after reading")
if !ClaudeKeychain.exists() {
    try! data("{\"claudeAiOauth\":{\"accessToken\":\"abc\",\"expiresAt\":1793800000000}}").write(to: URL(fileURLWithPath: tmp + "/claude/.credentials.json"))
    let l = Usage.readClaude()!
    check(l.access == "abc" && l.expires == Date(timeIntervalSince1970: 1793800000), "claude: credentials file read when no keychain item exists")
} else { print("SKIP claude file test: a Claude Code keychain item exists on this Mac") }

// ---- keychain through /usr/bin/security (no prompt): decoding, not-found, timeout; the secret is never printed ----
check(SecurityTool.decode(Data("{\"a\":1}\n".utf8)) == Data("{\"a\":1}".utf8), "security -w: trailing newline dropped")
check(SecurityTool.decode(Data("7b7d\n".utf8)) == Data("{}".utf8), "security -w: hex output decoded")
check(SecurityTool.decode(Data("\n".utf8)) == nil, "security -w: empty output is no secret")
if case .notFound = SecurityTool.findGenericPassword(service: "UsageGauge test item that does not exist \(UUID().uuidString)") { check(true, "security: missing item is notFound (exit 44)") } else { check(false, "security: missing item is notFound (exit 44)") }
let t0 = Date()
let slow = SecurityTool.run("/bin/sleep", ["5"], timeout: 0.5)
check(slow.status == .timedOut && Date().timeIntervalSince(t0) < 3, "security: a hung tool is stopped at the timeout")
check(SecurityTool.run("/nonexistent/tool", [], timeout: 1).status == .launchFailed, "security: missing tool reported, not a crash")
if ClaudeKeychain.exists() {
    if case .found(let d) = ClaudeKeychain.read() {
        check(!ClaudeKeychain.usedFallback && (try? JSONSerialization.jsonObject(with: d)) != nil, "claude: keychain item read through /usr/bin/security, no Security API fallback")
    } else { check(false, "claude: keychain item read through /usr/bin/security") }
} else { print("SKIP claude keychain read: no Claude Code keychain item on this Mac") }
try? FileManager.default.removeItem(atPath: tmp)

// ---- account change: never carry a value across logins ----
func okQ(_ key: String?, _ cred: String?, _ rem: Double) -> Quota { let q = Usage.ok(rem); q.name = "Claude"; q.accountKey = key; q.credKey = cred; q.lastOk = Date(); return q }
func failQ(_ key: String?, _ cred: String?, transient: Bool) -> Quota { let q = Quota.fail(transient ? "시간 초과(네트워크)" : "로그인 만료(401): 공식 도구로 다시 로그인", transient: transient); q.name = "Claude"; q.accountKey = key; q.credKey = cred; return q }
let m1 = Merge.merge(okQ("claude:A", "c1", 50), failQ("claude:B", "c2", transient: true), staleAfterMin: 12, hasLogin: true)
check(!m1.ok, "merge: failure on another account drops the previous account's value")
let m2 = Merge.merge(okQ("claude:A", "c1", 50), failQ("claude:A", "c1", transient: true), staleAfterMin: 12, hasLogin: true)
check(m2.ok && m2.remaining == 50 && m2.failing && !m2.stale, "merge: network blip on the same account keeps the value quietly")
let m3 = Merge.merge(okQ("claude:A", "c1", 50), failQ("claude:A", "c1", transient: false), staleAfterMin: 12, hasLogin: true)
check(m3.ok && m3.stale, "merge: auth error on the same account is shown right away")
let m4 = Merge.merge(okQ("claude:A", "c1", 50), failQ(nil, nil, transient: true), staleAfterMin: 12, hasLogin: true)
check(!m4.ok, "merge: unidentified login is not assumed to be the same")
let m5 = Merge.merge(okQ("claude:A", "c1", 50), okQ("claude:B", "c2", 90), staleAfterMin: 12, hasLogin: true)
check(m5.remaining == 90 && m5.accountChanged != nil, "merge: account switch shows the new account and notes it")

// ---- masking and hashing (same as UsageGauge.cs) ----
check(DashboardFeed.mask("abcdef@gmail.com") == "ab***@gmail.com", "mask: two characters and the domain")
check(DashboardFeed.mask("ID 12345678") == "ID***", "mask: id label keeps two characters only (same as C#)")
check(DashboardFeed.mask("@x.com") == "x***", "mask: same edge case as C# (no local part)")
check(Usage.hash("hello") == "2CF24DBA5FB0A30E26E83B2A", "hash: first 12 bytes of SHA-256, upper-case hex")

// ---- dashboard feed format (read by assemble.cjs) ----
let fc = okQ("codex:acct", "x", 60); fc.name = "Codex"; fc.windows = c1.windows; fc.account = "person@example.com"
let fl = cl; fl.name = "Claude"; fl.lastOk = Date()
let fg = Quota.noLoginFound(); fg.name = "Grok"
let text = DashboardFeed.limitsText([fc, fl, fg])
let rows = text.split(separator: "\n").map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
check(rows.count == 3 && rows[2]["status"] as? String == "unavailable", "feed: one line per service, no-login is unavailable")
let acct = rows[0]["account"] as! [String: Any]
check(acct["label"] as? String == "pe***@example.com" && (acct["key"] as? String)?.count == 24, "feed: masked label and hashed key only")
check(!text.contains("person@") && !text.contains("tok") && !text.contains("abc"), "feed: no email or token text")
let cd = (rows[0]["data"] as! [String: Any])["secondary_window"] as! [String: Any]
check(cd["window_seconds"] as? Double == 604800 && cd["reset_at"] as? Int == 1793800000, "feed: codex window fields")
try! data(text).write(to: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/dev/null"))
// ---- approved menu bar design ----
check(Design.tone(29.9) == .red && Design.tone(29) == .red && Design.tone(30) == .amber, "ring color: below 30 red, 30 amber")
check(Design.tone(59) == .amber && Design.tone(59.9) == .amber && Design.tone(60) == .green && Design.tone(100) == .green, "ring color: below 60 amber, 60 green")
func named(_ q: Quota, _ n: String) -> Quota { q.name = n; return q }
let noLogin = named(Quota.noLoginFound(), "Codex"), c86 = named(Usage.ok(86), "Claude"), g12 = named(Usage.ok(12), "Grok")
let notInst = Antigravity.notInstalled()[0]
check(Design.lowest([noLogin, c86, g12, notInst]) == 2, "most urgent: lowest value among services that returned one")
check(Design.lowest([noLogin, named(Quota.fail("서버 오류 500", transient: true), "Claude"), named(Quota.noLoginFound(), "Grok"), notInst]) == nil, "most urgent: none when nothing was read (no fake 0%)")
let used = named(Usage.ok(0), "Grok")
check(Design.lowest([named(Usage.ok(38), "Codex"), c86, used, notInst]) == 0, "most urgent: a used-up service is skipped while another has room (as in the mock)")
check(Design.lowest([noLogin, used]) == 1, "most urgent: used-up shown when it is the only value")
let tzS = TimeZone(identifier: "Asia/Seoul")!
var calS = Calendar(identifier: .gregorian); calS.timeZone = tzS
let nowS = calS.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 17, minute: 15))!
func atS(_ m: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date { calS.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: mi))! }
used.resetsAt = atS(11, 2, 14, 58)
let gUsed = Design.gauge(used, logo: "grok", now: nowS, tz: tzS)
check(gUsed.state == .usedUp && gUsed.percentText == "—" && gUsed.tone == .red && gUsed.caption == "월 14:58까지", "0%: red dash and '...까지'")
let gOff = Design.gauge(noLogin, logo: "codex", now: nowS, tz: tzS)
check(gOff.state == .off && gOff.tone == .off && gOff.caption == "로그인 필요" && gOff.fraction == 0, "no login: grey empty ring and '로그인 필요', not 0%")
check(gUsed.state != gOff.state && gUsed.tone != gOff.tone, "0% and no login look different")
check(Design.gauge(notInst, logo: "gemini").caption == "설치 안 됨", "agy missing: '설치 안 됨'")
let expiredQ = named(Quota.fail("로그인 만료(401): 공식 도구로 다시 로그인"), "Claude")
check(Design.gauge(expiredQ, logo: "claude").caption == "다시 로그인" && Design.gauge(expiredQ, logo: "claude").detail!.hasPrefix("로그인 만료"), "failure: short status, full text in the tooltip")
let c38 = named(Usage.ok(38), "Codex"); c38.resetsAt = atS(11, 4, 15, 35)
let g38 = Design.gauge(c38, logo: "codex", now: nowS, tz: tzS)
check(g38.percentText == "38" && g38.tone == .amber && abs(g38.fraction - 0.38) < 1e-9 && g38.caption == "11/4 15:35", "value gauge: number, color, ring share, reset")
check(Design.when(atS(10, 31, 0, 0), now: nowS, tz: tzS) == "오늘 밤 12시" && Design.when(atS(11, 6, 0, 0), now: nowS, tz: tzS) == "11/6"
      && Design.when(atS(10, 30, 21, 5), now: nowS, tz: tzS) == "오늘 21:05" && Design.when(atS(10, 31, 9, 0), now: nowS, tz: tzS) == "내일 09:00", "reset time texts")
let ca = named(Usage.ok(50), "Codex"); ca.accountKey = "codex:x"
let cb = named(Usage.ok(50), "Claude"); cb.accountKey = "claude:y"
let cc = named(Quota.fail("시간 초과(네트워크)", transient: true), "Grok"); cc.accountKey = "grok:z"
check(Design.header(lastCheck: nowS, main: [ca, cb, cc], now: nowS) == "방금 확인, 계정 3개", "header: signed-in accounts, including one whose lookup failed")
check(Design.header(lastCheck: nowS.addingTimeInterval(-300), main: [noLogin, named(Quota.noLoginFound(), "Claude"), named(Quota.noLoginFound(), "Grok")], now: nowS) == "5분 전 확인", "header: no accounts part when nobody is signed in")
// "지금 할 일": same rule as the dashboard (>= 40만 context, used in the last 6 hours, not a helper), hidden otherwise
func snap(_ rows: [[String: Any]]) -> [String: Any] { ["datasets": [["id": "claude_aside_local", "efficiency": ["status": "observed", "recentSessions": rows]]]] }
let iso = DashboardFeed.iso
let long = ["session": "s1", "project": "p1", "lastAt": iso(nowS.addingTimeInterval(-600)), "lastContext": 852373] as [String: Any]
check(Design.todo(snapshot: nil, names: [:], helpers: [], now: nowS) == nil, "todo: hidden without dashboard data")
check(Design.todo(snapshot: snap([]), names: [:], helpers: [], now: nowS) == nil, "todo: hidden when there is nothing")
check(Design.todo(snapshot: snap([["session": "s1", "lastAt": iso(nowS), "lastContext": 399999]]), names: [:], helpers: [], now: nowS) == nil, "todo: hidden under 40만 tokens")
check(Design.todo(snapshot: snap([["session": "s1", "lastAt": iso(nowS.addingTimeInterval(-6 * 3600)), "lastContext": 900000]]), names: [:], helpers: [], now: nowS) == nil, "todo: hidden after 6 hours")
check(Design.todo(snapshot: snap([long]), names: [:], helpers: ["s1"], now: nowS) == nil, "todo: helper conversations skipped")
check(Design.todo(snapshot: snap([long]), names: ["s1": "[유령마작] 점검, 스토리, 최적화"], helpers: [], now: nowS)
      == Design.Todo(name: "\"[유령마작] 점검, 스토리, 최적화\"", tokens: "85.2만 토큰"), "todo: conversation title and context, dashboard number format")
check(Design.todo(snapshot: snap([long, ["session": "s2", "project": "p2", "lastAt": iso(nowS), "lastContext": 1200000]]), names: ["p2": "맞고"], helpers: [], now: nowS)?.name == "맞고 대화", "todo: the largest one first, project name when untitled")
check(Design.compact(1_199_522_966) == "12억" && Design.compact(950000) == "95만" && Design.compact(1234) == "1,234", "compact numbers like the dashboard")
check(Design.logoFile("codex", dark: false) == "codex-dark" && Design.logoFile("grok", dark: false) == "grok-dark" && Design.logoFile("claude", dark: false) == "claude" && Design.logoFile("codex", dark: true) == "codex", "light screens use the dark-ink logos")
// ---- menu bar variant C ----
do {
    let nowM = Date(timeIntervalSince1970: 1793359141)   // 2026-10-30 11:19:01Z
    let cx = Usage.codexResult(200, data("{\"rate_limit\":{\"primary_window\":{\"used_percent\":63,\"limit_window_seconds\":604800,\"reset_at\":1793774137}}}")); cx.lastOk = Date()   // fresh value (staleness is measured against the real clock)
    let cl = Usage.ok(0); cl.resetsAt = nowM.addingTimeInterval(2 * 86400 + 15.6 * 3600); cl.lastOk = Date()
    cl.windows = [UsageWindow(key: "seven_day", used: 100, reset: cl.resetsAt), UsageWindow(key: "five_hour", used: 0, reset: nil)]
    let es = MenuBarStrip.entries(main: [cx, cl, named(Quota.fail("서버 오류 500", transient: true), "Grok")], ag: [named(Quota.noLoginFound(), "Gemini")])
    check(es.map { $0.logo } == ["codex", "claude"], "menu bar C: unknown services hidden")
    check(es.map { MenuBarStrip.numberText($0, now: nowM, tz: tzS) } == ["37", "월"], "menu bar C: numbers without a % sign, used-up shows the refill weekday")
    check(MenuBarStrip.tooltip(es, now: nowM, tz: tzS) == "Codex 주간 37% 남음\nClaude 주간 다 씀, 월 11:55에 다시 차요", "menu bar C: tooltip, one line per item")
    let c5 = Usage.ok(80); c5.windows = [UsageWindow(key: "seven_day", used: 20, reset: nil), UsageWindow(key: "five_hour", used: 90, reset: nil), UsageWindow(key: "seven_day_opus", used: 99, reset: nil)]
    let b5 = MenuBarStrip.binding(c5)
    check(b5.window == "5시간" && abs(b5.remaining - 10) < 0.001, "menu bar C: the binding window (5-hour) is shown, model-only pools ignored")
    check(MenuBarStrip.binding(c1).window == "주간" && MenuBarStrip.binding(c1).remaining == 60, "menu bar C: codex weekly binds when it is lower than the 5-hour window")
    check(MenuBarStrip.until(nowM.addingTimeInterval(200 * 60), now: nowM) == "3시간 20분 뒤" && MenuBarStrip.until(nowM.addingTimeInterval(900), now: nowM) == "15분 뒤", "menu bar C: reset countdown")
    check(MenuBarStrip.entries(main: [named(Quota.noLoginFound(), "Codex")], ag: []).isEmpty, "menu bar C: nothing read, nothing shown (falls back to the empty ring)")

    // fixed order Codex, Claude, Grok, Gemini 4 Argon, Antigravity (a used-up service is not moved to the end)
    let agB: [String: [String: Any]] = [
        "gemini-weekly": ["window": "weekly", "remaining_fraction": 1, "reset_time": "2026-11-06T11:58:12Z"],
        "gemini-5h": ["window": "5h", "remaining_fraction": 1, "reset_time": "2026-10-30T16:58:12Z"],
        "3p-weekly": ["window": "weekly", "remaining_fraction": 1, "reset_time": "2026-11-06T11:58:12Z"],
        "3p-5h": ["window": "5h", "remaining_fraction": 1, "reset_time": "2026-10-30T16:58:12Z"],
        "gemini-argon-wtu-weekly": ["window": "weekly", "remaining_fraction": 0.16887587308883667, "reset_time": "2026-11-04T03:42:44Z"]]
    let agQ = Antigravity.split(agB)
    check(agQ.count == 2 && agQ[0].ok && abs(agQ[0].remaining - 16.8876) < 0.001 && agQ[0].name == "Gemini 4 Argon", "argon split: the Argon bucket is its own item")
    check(agQ[1].ok && agQ[1].remaining == 100 && agQ[1].windows.count == 4 && agQ[1].resetsAt == ISO8601DateFormatter().date(from: "2026-11-06T11:58:12Z"), "argon split: the rest is Gemini general + Claude, GPT (weekly and 5-hour)")
    check(Antigravity.isArgon("gemini-argon-wtu-weekly") && Antigravity.isArgon("gemini-pro-weekly") && !Antigravity.isArgon("gemini-weekly") && !Antigravity.isArgon("gemini-5h") && !Antigravity.isArgon("3p-weekly"), "argon split: which buckets are Argon (same rule as Windows plus the argon name)")
    var agB2 = agB; agB2["3p-5h"] = ["window": "5h", "remaining_fraction": 0, "reset_time": "2026-10-30T16:58:12Z"]
    let rest0 = Antigravity.split(agB2)[1], rb = MenuBarStrip.binding(rest0)
    check(rest0.remaining == 100 && rb.window == "5시간" && rb.remaining == 0, "argon split: the binding bucket of the rest (Claude, GPT 5-hour used up) is shown")
    var agB3 = agB; agB3.removeValue(forKey: "gemini-argon-wtu-weekly")
    check(!Antigravity.split(agB3)[0].ok && Antigravity.split(agB3)[1].ok, "argon split: no Argon bucket, only the Antigravity item")
    let grUsed = named(Usage.ok(0), "Grok"); grUsed.resetsAt = nowM.addingTimeInterval(3 * 3600); grUsed.lastOk = Date()
    let order = MenuBarStrip.entries(main: [cx, cl, grUsed], ag: agQ)
    check(order.map { $0.logo } == ["codex", "claude", "grok", "gemini", "antigravity"], "order: fixed Codex, Claude, Grok, Gemini 4 Argon, Antigravity")
    check(order.map { MenuBarStrip.numberText($0, now: nowM, tz: tzS) } == ["37", "월", "23시", "17", "100"], "order: used-up shows refill day or hour, usable shows the number")
    check(MenuBarStrip.tooltip(order, now: nowM, tz: tzS) == "Codex 주간 37% 남음\nClaude 주간 다 씀, 월 11:55에 다시 차요\nGrok 주간 다 씀, 오늘 23:19에 다시 차요\nGemini 4 Argon 주간 17% 남음\nAntigravity(Gemini, Claude, GPT) 주간 100% 남음", "tooltip: all items in the new order, full text")
    // refill label: local weekday, the hour within 24 hours
    check(MenuBarStrip.refillLabel(atS(11, 2, 12, 0), now: nowS, tz: tzS) == "월" && MenuBarStrip.refillLabel(atS(11, 4, 12, 43), now: nowS, tz: tzS) == "수", "refill label: Korean weekday")
    check(MenuBarStrip.refillLabel(atS(10, 31, 14, 0), now: nowS, tz: tzS) == "14시" && MenuBarStrip.refillLabel(atS(10, 30, 23, 59), now: nowS, tz: tzS) == "23시", "refill label: the hour when less than 24 hours away")
    check(MenuBarStrip.refillLabel(atS(10, 31, 17, 15), now: nowS, tz: tzS) == "토" && MenuBarStrip.refillLabel(nil, now: nowS, tz: tzS) == "0" && MenuBarStrip.refillLabel(atS(10, 30, 17, 0), now: nowS, tz: tzS) == "곧", "refill label: 24 hours or more is a weekday; no reset 0; passed 곧")
    check(MenuBarStrip.refillLabel(atS(11, 2, 12, 0), now: nowS, tz: TimeZone(identifier: "America/Los_Angeles")!) == "일", "refill label: weekday in the local time zone")
    // glyphs: every key has a vector path that parses and fills the 16 pt box
    for k in MenuBarStrip.order {
        let p = MenuBarStrip.glyphPath(k)
        check(p != nil && p!.elementCount > 10 && !p!.bounds.isEmpty, "glyph: \(k) vector path parses")
    }
    do {
        let sp = MenuBarStrip.svgPath("M10 20L30-40h5v-5C1 2 3 4 5 6Z")
        var pts = [NSPoint](repeating: .zero, count: 3)
        var got: [NSPoint] = []
        for i in 0..<5 { _ = sp.element(at: i, associatedPoints: &pts); got.append(i == 4 ? pts[2] : pts[0]) }
        check(got == [NSPoint(x: 10, y: 20), NSPoint(x: 30, y: -40), NSPoint(x: 35, y: -40), NSPoint(x: 35, y: -45), NSPoint(x: 5, y: 6)]
              && sp.element(at: 5) == .closePath, "glyph: path parser handles signs and relative commands")
    }
    let img = MenuBarStrip.image(order, now: nowM)
    check(img.isTemplate && img.size.height == 22 && img.size.width > 5 * 16, "menu bar image: one template image for all items")
}
print("RESULT \(passed) mac logic tests passed")
