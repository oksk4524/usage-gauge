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
check(ClaudeKeychain.hasLogin(Data("{\"claudeAiOauth\":{\"accessToken\":\"a\"}}".utf8)) && !ClaudeKeychain.hasLogin(Data("{\"mcpOAuth\":{}}".utf8)), "claude: an item with only MCP logins is not the Claude login")
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
    // weekly choice (2026-10-30): the number is always the weekly limit, even when the 5-hour window is lower
    let w5 = MenuBarStrip.weekly(c5)
    check(w5.label == "주간" && w5.remaining == 80, "weekly: Claude shows the weekly limit although the 5-hour window is lower")
    check(MenuBarStrip.others(c5) == [MenuBarStrip.Window(label: "5시간", remaining: 10, reset: nil)], "weekly: the 5-hour window is the other window, model-only pools ignored")
    check(MenuBarStrip.weekly(c1).remaining == 60 && MenuBarStrip.others(c1).map(\.label) == ["5시간"] && abs(MenuBarStrip.others(c1)[0].remaining - 87.5) < 0.001,
          "weekly: Codex with both windows shows the 604800 s one, the 18000 s one is the other window")
    check(MenuBarStrip.blocked(c5) == nil, "weekly: 10% left in the 5-hour window is not a block")
    let ce = MenuBarStrip.entries(main: [c1, c5], ag: [])
    check(ce.map { $0.window } == ["주간", "주간"] && ce.map { MenuBarStrip.numberText($0) } == ["60", "80"] && ce.allSatisfy { $0.blocked == nil },
          "weekly: menu bar numbers are the weekly limits")
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
    let rest0 = Antigravity.split(agB2)[1]
    check(rest0.remaining == 100 && MenuBarStrip.weekly(rest0).remaining == 100, "argon split: the rest keeps its weekly value when a 5-hour bucket is used up")
    check(MenuBarStrip.blocked(rest0) == MenuBarStrip.Window(label: "5시간", remaining: 0, reset: ISO8601DateFormatter().date(from: "2026-10-30T16:58:12Z")),
          "argon split: a used-up 5-hour bucket of the rest marks the item as blocked")
    // 5-hour buckets never count toward the weekly value, in either group (even a lower one, even an argon 5-hour bucket)
    var agB4 = agB; agB4["gemini-5h"] = ["window": "5h", "remaining_fraction": 0.05, "reset_time": "2026-10-30T16:58:12Z"]
    agB4["gemini-argon-5h"] = ["window": "5h", "remaining_fraction": 0.01, "reset_time": "2026-10-30T16:58:12Z"]
    let ag4 = Antigravity.split(agB4)
    check(Antigravity.isArgon("gemini-argon-5h") && abs(ag4[0].remaining - 16.8876) < 0.001 && ag4[1].remaining == 100,
          "antigravity: weekly values leave out 5-hour buckets (Argon 17, the rest 100)")
    check(ag4[0].windows.filter { $0.key == "five_hour" }.count == 1 && ag4[1].windows.filter { $0.key == "five_hour" }.count == 2,
          "antigravity: 5-hour buckets stay as other windows of their group")
    check(abs(MenuBarStrip.others(ag4[1])[0].remaining - 5) < 0.001 && MenuBarStrip.blocked(ag4[1]) == nil && MenuBarStrip.blocked(ag4[0]) == nil,
          "antigravity: the lowest 5-hour bucket is the other window; 1% left is not a block (only 0 is)")
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
    // glyphs (variant A): every key has a 1x and a 2x mask of the expected size, with real ink and no outline added
    for k in MenuBarStrip.order {
        let g = MenuBarGlyphs.named(k), gi = MenuBarGlyphs.image(k)
        let reps = (gi?.representations ?? []).compactMap { $0 as? NSBitmapImageRep }
        let ok = g != nil && reps.count == 2 && reps[0].pixelsWide == g!.cellW && reps[0].pixelsHigh == g!.cellH
            && reps[1].pixelsWide == 2 * g!.cellW && reps[1].pixelsHigh == 2 * g!.cellH && gi!.isTemplate
        check(ok, "glyph: \(k) has 1x and 2x masks")
        if ok {
            var ink = 0.0, solid = 0
            for y in 0..<g!.cellH { for x in 0..<g!.cellW { let a = Double(reps[0].colorAt(x: x, y: y)?.alphaComponent ?? 0); ink += a; if a > 0.9 { solid += 1 } } }
            check(ink > 15 && solid > 5 && ink < Double(g!.cellW * g!.cellH) * 0.7, "glyph: \(k) 1x mask has ink at natural weight")
        }
    }
    check([MenuBarGlyphs.codex, MenuBarGlyphs.claude, MenuBarGlyphs.grok].allSatisfy { $0.cellH == 16 } && [MenuBarGlyphs.gemini, MenuBarGlyphs.antigravity].allSatisfy { $0.cellH == 15 },
          "glyph: logos 15 px tall (Gemini star and Antigravity 14 px) plus the 1 px placement margin")
    check(MenuBarStrip.fillHeight(0) == 0 && MenuBarStrip.fillHeight(100) == 12 && MenuBarStrip.fillHeight(37) == 4
          && MenuBarStrip.fillHeight(1) == 2 && MenuBarStrip.fillHeight(17) == 2, "bar: 12 pt filled from the bottom, at least 2 pt")
    check(MenuBarStrip.textFont("37") === MenuBarStrip.font && MenuBarStrip.textFont("0") === MenuBarStrip.font
          && MenuBarStrip.textFont("월").pointSize == 14 && MenuBarStrip.textFont("14시").pointSize == 14 && MenuBarStrip.font.pointSize == 13,
          "menu bar text: numbers 13 pt, refill day/hour 14 pt")
    let img = MenuBarStrip.image(order, now: nowM)
    check(img.isTemplate && img.size.height == 22 && img.size.width > 5 * 16, "menu bar image: one template image for all items")
    // render at 1x and check the pixels of the first item: the logo mask lands 1:1, the bar is a 2 px track + fill
    do {
        let w = Int(img.size.width), h = 22
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = img.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(origin: .zero, size: img.size))
        NSGraphicsContext.restoreGraphicsState()
        func a(_ x: Int, _ y: Int) -> Double { Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) }  // y from the top
        let m = MenuBarGlyphs.image("codex")!.representations[0] as! NSBitmapImageRep
        var maxDiff = 0.0
        for y in 0..<16 { for x in 0..<16 { maxDiff = max(maxDiff, abs(a(x, 4 + y) - Double(m.colorAt(x: x, y: y)?.alphaComponent ?? 0))) } }
        check(maxDiff < 0.02, "menu bar image: the Codex logo is drawn 1:1 on whole pixels at 1x (max diff \(maxDiff))")
        let bx = 15 + 3   // Codex advance + gap; 37 left = 4 px filled at the bottom of rows 6...17
        check(abs(a(bx, 8) - 0.3) < 0.05 && a(bx, 6) > 0.1 && abs(a(bx + 1, 10) - 0.3) < 0.05 && a(bx, 15) > 0.95 && a(bx + 1, 16) > 0.95
              && a(bx - 1, 12) < 0.02 && a(bx + 2, 12) < 0.02 && a(bx, 5) < 0.02 && a(bx, 18) < 0.02,
              "menu bar image: 2x12 bar, faint 30% track, filled from the bottom, no outline")
        let cbx = 15 + 3 + 2 + 3 + Int(ceil(("37" as NSString).size(withAttributes: [.font: MenuBarStrip.font]).width)) + 10 + 16 + 3
        check(a(cbx, 11) > 0.2 && a(cbx, 11) < 0.4 && a(cbx, 16) < 0.4, "menu bar image: a used-up service shows only the faint track")
    }
}

// ---- weekly ring + 5-hour line, and the 5-hour-exhausted marker in the menu bar ----
do {
    let tz = TimeZone(identifier: "Asia/Seoul")!
    var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 22, minute: 40))!
    let r5 = cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 1, minute: 19))!
    let rw = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 9, minute: 0))!
    func claude(_ week: Double, _ five: Double) -> Quota {
        let q = Usage.ok(week); q.name = "Claude"; q.resetsAt = rw; q.lastOk = Date()
        q.windows = [UsageWindow(key: "seven_day", used: 100 - week, reset: rw), UsageWindow(key: "five_hour", used: 100 - five, reset: r5),
                     UsageWindow(key: "seven_day_opus", used: 100, reset: rw)]
        return q
    }
    // popover: the ring is weekly; a small line shows the 5-hour window
    let g55 = Design.gauge(claude(99, 55), logo: "claude", now: now, tz: tz)
    check(g55.percentText == "99" && abs(g55.fraction - 0.99) < 1e-9 && g55.second == "5시간 55%" && g55.secondReset == nil && !g55.secondUsedUp,
          "ring: weekly 99, second line '5시간 55%' without a reset time")
    let g12 = Design.gauge(claude(70, 12), logo: "claude", now: now, tz: tz)
    check(g12.second == "5시간 12%" && g12.secondReset == "01:19에 다시 차요" && !g12.secondUsedUp, "ring: a low 5-hour window adds when it fills again")
    let g0 = Design.gauge(claude(99, 0), logo: "claude", now: now, tz: tz)
    check(g0.percentText == "99" && g0.tone == .green && g0.second == "5시간 다 씀" && g0.secondReset == "01:19에 다시 차요" && g0.secondUsedUp,
          "ring: 5-hour used up keeps the weekly ring, the line says 다 씀 and the refill time")
    check(g0.detail == "주간 99% 남음\n5시간 다 씀, 01:19에 다시 차요", "ring: tooltip has the weekly and the 5-hour line")
    let grokOnly = Usage.ok(40); grokOnly.windows = [UsageWindow(key: "weekly", used: 60, reset: nil)]
    check(Design.gauge(grokOnly, logo: "grok", now: now, tz: tz).second == nil, "ring: no other window, no second line")
    check(Design.gauge(claude(0, 100), logo: "claude", now: now, tz: tz).second == nil, "ring: weekly used up keeps the old look, no 5-hour line")
    // menu bar: 5-hour used up while weekly has room -> weekly number, empty bar, refill hour, tooltip line
    let blockedQ = claude(99, 0)
    let none = Quota.noLoginFound()   // Codex not signed in: Claude is the only item
    let es = MenuBarStrip.entries(main: [none, blockedQ], ag: [])
    check(es.count == 1 && es[0].logo == "claude" && es[0].window == "주간" && es[0].remaining == 99 && es[0].blocked?.label == "5시간" && es[0].blocked?.reset == r5,
          "marker: 0% in the 5-hour window blocks, the item stays with its weekly value")
    check(MenuBarStrip.numberText(es[0], now: now, tz: tz) == "99" && MenuBarStrip.blockedText(es[0], now: now, tz: tz) == "1시"
          && MenuBarStrip.barRemaining(es[0]) == 0, "marker: weekly number, empty bar, refill hour like a used-up item")
    check(MenuBarStrip.tooltip(es, now: now, tz: tz) == "Claude 주간 99% 남음\n5시간 다 씀, 01:19에 다시 차요", "marker: tooltip")
    let open = MenuBarStrip.entries(main: [none, claude(99, 1)], ag: [])[0]
    check(open.blocked == nil && MenuBarStrip.blockedText(open, now: now, tz: tz) == nil && MenuBarStrip.barRemaining(open) == 99, "marker: 1% left is not blocked")
    check(MenuBarStrip.entries(main: [none, claude(99, 1.5)], ag: [])[0].blocked == nil && MenuBarStrip.entries(main: [none, claude(99, 0.4)], ag: [])[0].blocked == nil,
          "exhausted only at 0: 1.5% and 0.4% left are not used up")
    let g1 = Design.gauge(claude(99, 1), logo: "claude", now: now, tz: tz)
    check(g1.second == "5시간 1%" && !g1.secondUsedUp && g1.detail?.contains("5시간 1% 남음") == true, "exhausted only at 0: 1% shows as 1")
    check(MenuBarStrip.isUsedUp(MenuBarStrip.Window(label: "5시간", remaining: 0, reset: nil)) && !MenuBarStrip.isUsedUp(MenuBarStrip.Window(label: "5시간", remaining: 1, reset: nil)),
          "exhausted threshold: 0 is used up, 1 is not")
    // empty weekly keeps the weekday label and is never marked as 5-hour blocked
    let emptyWeek = MenuBarStrip.entries(main: [none, claude(0, 0)], ag: [])[0]
    check(emptyWeek.blocked == nil && MenuBarStrip.numberText(emptyWeek, now: now, tz: tz) == "목", "marker: weekly used up keeps the weekday label")
    // drawn: the blocked item is wider by the refill hour, and its bar has no fill
    let imgB = MenuBarStrip.image(es, now: now), imgO = MenuBarStrip.image([open], now: now)
    let hourW = ceil(("1시" as NSString).size(withAttributes: [.font: MenuBarStrip.labelFont]).width)
    check(abs(imgB.size.width - imgO.size.width - (MenuBarStrip.gap + hourW)) < 0.5, "marker: the refill hour follows the weekly number")
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(imgB.size.width), pixelsHigh: 22, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = imgB.size
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    imgB.draw(in: NSRect(origin: .zero, size: imgB.size)); NSGraphicsContext.restoreGraphicsState()
    let bx = MenuBarGlyphs.claude.advance + 3
    let bottom = Double(rep.colorAt(x: bx, y: 16)?.alphaComponent ?? 0)
    check(bottom > 0.2 && bottom < 0.4, "marker: the bar is only the faint track")
}

// ---- refresh scheduling (Refresh.swift): debounce, minimum gaps, idle polling, backoff ----
do {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    var s = ProviderState()
    check(Sched.decide(s, now: t0, idle: 180) == .start, "sched: never looked up -> start now")
    Sched.started(&s, now: t0)
    check(Sched.decide(s, now: at(1), idle: 180) == .busy, "sched: one lookup at a time per service")
    Sched.finished(&s, now: at(2), transient: false, rateLimited: false, retryAfter: nil)
    check(Sched.decide(s, now: at(100), idle: 180) == .wait(at(180)), "sched: idle poll waits 3 min after the last start")
    check(Sched.decide(s, now: at(180), idle: 180) == .start, "sched: idle poll due at 3 min")
    Sched.request(&s, gap: 60, reason: "활동")
    check(Sched.decide(s, now: at(30), idle: 180) == .wait(at(60)), "sched: activity respects the minimum gap (Claude 60 s)")
    check(Sched.decide(s, now: at(61), idle: 180) == .start, "sched: activity starts once the gap has passed")
    Sched.request(&s, gap: 120, reason: "broad")
    check(s.requestGap == 60 && s.reason == "활동", "sched: a wider request doesn't loosen a pending tighter one")
    Sched.started(&s, now: at(61))
    check(s.requestGap == nil, "sched: a start serves the pending request")
    Sched.request(&s, gap: 60, reason: "활동 중 새 활동")
    Sched.finished(&s, now: at(63), transient: false, rateLimited: false, retryAfter: nil)
    check(Sched.decide(s, now: at(70), idle: 180) == .wait(at(121)), "sched: activity during a lookup is served after the gap, not dropped")

    // backoff
    check(RefreshPolicy.backoff(failures: 1, rateLimited: false, retryAfter: nil) == 60
          && RefreshPolicy.backoff(failures: 3, rateLimited: false, retryAfter: nil) == 240
          && RefreshPolicy.backoff(failures: 12, rateLimited: false, retryAfter: nil) == 1800, "backoff: 1, 2, 4 ... min, capped at 30")
    check(RefreshPolicy.backoff(failures: 1, rateLimited: true, retryAfter: nil) == 120, "backoff: a 429 waits at least 2 min")
    check(RefreshPolicy.backoff(failures: 1, rateLimited: true, retryAfter: 900) == 900
          && RefreshPolicy.backoff(failures: 1, rateLimited: true, retryAfter: 99999) == 3600, "backoff: Retry-After respected, capped at 1 h")
    var b = ProviderState()
    Sched.started(&b, now: t0)
    Sched.finished(&b, now: at(1), transient: true, rateLimited: true, retryAfter: 300)
    Sched.request(&b, gap: 45, reason: "활동")
    check(Sched.decide(b, now: at(100), idle: 180) == .wait(at(301)), "backoff: activity can't hurry a 429 block")
    Sched.clearNetworkBackoff(&b, now: at(100))
    check(Sched.decide(b, now: at(100), idle: 180) == .wait(at(301)), "backoff: wake/network back keeps a 429 block")
    check(Sched.decide(b, now: at(301), idle: 180) == .start, "backoff: one retry when the block ends")
    var n = ProviderState()
    Sched.started(&n, now: t0); Sched.finished(&n, now: at(1), transient: true, rateLimited: false, retryAfter: nil)
    Sched.started(&n, now: at(61)); Sched.finished(&n, now: at(62), transient: true, rateLimited: false, retryAfter: nil)
    check(n.failures == 2 && n.blockedUntil == at(182), "backoff: second network failure waits 2 min")
    Sched.clearNetworkBackoff(&n, now: at(90))
    check(Sched.decide(n, now: at(90), idle: 180) == .start, "backoff: network back retries a network failure at once")
    Sched.started(&n, now: at(90)); Sched.finished(&n, now: at(91), transient: false, rateLimited: false, retryAfter: nil)
    check(n.failures == 0 && n.blockedUntil == nil, "backoff: success clears it")
    check(Usage.retryAfterSeconds("120") == 120 && Usage.retryAfterSeconds("x") == nil
          && Usage.retryAfterSeconds("Wed, 21 Oct 2015 07:28:00 GMT", now: ISO8601DateFormatter().date(from: "2015-10-21T07:27:00Z")!) == 60,
          "retry-after: seconds and HTTP date")
    check(Usage.httpError(429).rateLimited && !Usage.httpError(503).rateLimited, "429 is marked rate limited")

    // debounce
    var d = Debouncer()
    check(d.takeIfDue(now: t0) == nil, "debounce: nothing noted, nothing due")
    d.note([.claude], broad: false, asideSession: true, label: "Aside claude-code", at: t0)
    check(d.due() == at(10) && d.takeIfDue(now: at(9)) == nil, "debounce: 10 s after the last activity")
    d.note([.claude], broad: true, asideSession: true, label: "Aside", at: at(8))
    check(d.due() == at(18), "debounce: new activity pushes it back")
    for i in stride(from: 16.0, through: 40, by: 4) { d.note([.codex], broad: false, asideSession: false, label: "Codex", at: at(i)) }
    check(d.due() == at(30), "debounce: but no later than 30 s after the first activity")
    let got = d.takeIfDue(now: at(30))!
    check(got.specific == [.claude, .codex] && got.broad.isEmpty, "debounce: services collected; state.db with a chat file is not broad")
    check(got.label == "Aside claude-code, Aside, Codex" && d.first == nil, "debounce: labels kept, then reset")
    var dl = Debouncer()
    dl.note([.claude], broad: true, asideSession: true, label: "Aside claude-code, Aside", at: t0)
    dl.note([.agy], broad: false, asideSession: false, label: "agy, Aside claude-code", at: t0)
    check(dl.labels == ["Aside claude-code", "Aside", "agy"], "debounce: log labels are not repeated")
    var e = Debouncer()
    e.note([], broad: true, asideSession: false, label: "Aside", at: t0)
    let g2 = e.takeIfDue(now: at(10))!
    check(g2.specific.isEmpty && g2.broad == Provider.quick, "debounce: Aside state.db alone -> all quick services at the broad gap")
    check(RefreshPolicy.minGap(.codex) == 45 && RefreshPolicy.minGap(.grok) == 45 && RefreshPolicy.minGap(.claude) == 90
          && RefreshPolicy.minGap(.agy) == 600 && RefreshPolicy.idle(.codex) == 180 && RefreshPolicy.idle(.grok) == 180
          && RefreshPolicy.idle(.claude) == 180 && RefreshPolicy.idle(.agy) == 1200, "policy: gaps and idle intervals (Claude 90 s, agy 10/20 min)")
    check(!RefreshPolicy.followsGeneralTriggers.contains(.agy) && RefreshPolicy.followsGeneralTriggers.contains(.claude),
          "policy: popover open, wake and network change don't start agy")

    // Claude: adaptive minimum gap
    var c = ProviderState()
    Sched.started(&c, now: t0); Sched.finished(&c, now: at(1), transient: false, rateLimited: false, retryAfter: nil, adaptive: true)
    check(c.floorGap == 90, "claude gap: starts at 90 s")
    Sched.request(&c, gap: RefreshPolicy.forceMinGap, reason: "새로고침")
    check(Sched.decide(c, now: at(30), idle: 180) == .wait(at(90)), "claude gap: even the refresh button waits 90 s")
    Sched.started(&c, now: at(90)); Sched.finished(&c, now: at(91), transient: true, rateLimited: true, retryAfter: nil, adaptive: true)
    check(c.floorGap == 180 && c.blockedUntil == at(271), "claude gap: a 429 doubles it to 3 min and blocks that long")
    Sched.started(&c, now: at(271)); Sched.finished(&c, now: at(272), transient: true, rateLimited: true, retryAfter: nil, adaptive: true)
    check(c.floorGap == 360, "claude gap: a second 429 doubles it again")
    Sched.started(&c, now: at(632)); Sched.finished(&c, now: at(633), transient: true, rateLimited: true, retryAfter: nil, adaptive: true)
    Sched.started(&c, now: at(1233)); Sched.finished(&c, now: at(1234), transient: true, rateLimited: true, retryAfter: nil, adaptive: true)
    check(c.floorGap == 600 && c.blockedUntil == at(1834), "claude gap: capped at 10 min")
    Sched.started(&c, now: at(1834)); Sched.finished(&c, now: at(1835), transient: true, rateLimited: true, retryAfter: 1500, adaptive: true)
    check(c.floorGap == 600 && c.blockedUntil == at(3335), "claude gap: a longer Retry-After wins for the block")
    check(Sched.decide(c, now: at(3000), idle: 180) == .wait(at(3335)), "claude gap: activity can't hurry the block")
    var tt = 3335.0
    for _ in 0..<2 { Sched.started(&c, now: at(tt)); Sched.finished(&c, now: at(tt + 1), transient: false, rateLimited: false, retryAfter: nil, adaptive: true); tt += 600 }
    check(c.floorGap == 600 && c.okStreak == 2 && c.blockedUntil == nil, "claude gap: two successes keep it")
    check(Sched.decide(c, now: at(tt - 300), idle: 180) == .wait(at(tt)), "claude gap: idle polling waits for the wider gap too")
    Sched.started(&c, now: at(tt)); Sched.finished(&c, now: at(tt + 1), transient: false, rateLimited: false, retryAfter: nil, adaptive: true)
    check(c.floorGap == 300 && c.okStreak == 0, "claude gap: the third success in a row halves it")
    for _ in 0..<3 { tt += 300; Sched.started(&c, now: at(tt)); Sched.finished(&c, now: at(tt + 1), transient: false, rateLimited: false, retryAfter: nil, adaptive: true) }
    check(c.floorGap == 150, "claude gap: three more halve it again")
    for _ in 0..<2 { tt += 150; Sched.started(&c, now: at(tt)); Sched.finished(&c, now: at(tt + 1), transient: false, rateLimited: false, retryAfter: nil, adaptive: true) }
    tt += 150; Sched.started(&c, now: at(tt)); Sched.finished(&c, now: at(tt + 1), transient: true, rateLimited: false, retryAfter: nil, adaptive: true)
    check(c.okStreak == 0 && c.floorGap == 150 && !c.rateLimited, "claude gap: a network failure breaks the streak, keeps the gap")
    for _ in 0..<3 { tt += 200; Sched.started(&c, now: at(tt)); Sched.finished(&c, now: at(tt + 1), transient: false, rateLimited: false, retryAfter: nil, adaptive: true) }
    check(c.floorGap == 90, "claude gap: never below 90 s")
    var nonAdaptive = ProviderState()
    Sched.started(&nonAdaptive, now: t0); Sched.finished(&nonAdaptive, now: at(1), transient: true, rateLimited: true, retryAfter: nil)
    check(nonAdaptive.floorGap == 0 && nonAdaptive.blockedUntil == at(121), "other services: 429 keeps the old 2 min backoff")

    // agy: 10 min floor for every request, 20 min idle
    var ag = ProviderState(); ag.floorGap = RefreshPolicy.minGap(.agy)
    Sched.started(&ag, now: t0); Sched.finished(&ag, now: at(9), transient: false, rateLimited: false, retryAfter: nil)
    Sched.request(&ag, gap: RefreshPolicy.forceMinGap, reason: "새로고침")
    check(Sched.decide(ag, now: at(60), idle: RefreshPolicy.idle(.agy)) == .wait(at(600)), "agy: no run sooner than 10 min, even from the button")
    ag.requestGap = nil
    check(Sched.decide(ag, now: at(700), idle: RefreshPolicy.idle(.agy)) == .wait(at(1200)), "agy: idle run every 20 min")
    // after a backoff ends the minimum gap since the last start still holds
    var agT = ProviderState(); agT.floorGap = RefreshPolicy.minGap(.agy)
    Sched.started(&agT, now: t0); Sched.finished(&agT, now: at(30), transient: true, rateLimited: false, retryAfter: nil)
    check(agT.blockedUntil == at(90) && Sched.decide(agT, now: at(90), idle: RefreshPolicy.idle(.agy)) == .wait(at(600)),
          "floor after backoff: agy timeout at 30 s, backoff ends at 90 s, the retry still waits for 10 min after the start")
    check(Sched.decide(agT, now: at(600), idle: RefreshPolicy.idle(.agy)) == .start, "floor after backoff: agy retries once both have passed")
    var cl = ProviderState()
    Sched.started(&cl, now: t0); Sched.finished(&cl, now: at(1), transient: false, rateLimited: false, retryAfter: nil, adaptive: true)
    Sched.started(&cl, now: at(200)); Sched.finished(&cl, now: at(201), transient: true, rateLimited: false, retryAfter: nil, adaptive: true)
    check(cl.blockedUntil == at(261) && Sched.decide(cl, now: at(261), idle: 180) == .wait(at(290)),
          "floor after backoff: Claude's 60 s network backoff can't beat its 90 s gap")
    Sched.clearNetworkBackoff(&cl, now: at(230))
    check(Sched.decide(cl, now: at(230), idle: 180) == .wait(at(290)), "floor after backoff: clearing a network backoff still waits for the gap")
    var lg = ProviderState(); lg.floorGap = 0
    Sched.started(&lg, now: t0); Sched.finished(&lg, now: at(1), transient: true, rateLimited: true, retryAfter: 300)
    check(Sched.decide(lg, now: at(301), idle: 180) == .start, "floor after backoff: a block longer than the gap is unchanged")
    // a general trigger (wake, network back) never clears agy's backoff or asks for agy
    var all: [Provider: ProviderState] = Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, ProviderState()) })
    all[.agy]!.floorGap = RefreshPolicy.minGap(.agy)
    for p in [Provider.codex, .agy] { Sched.started(&all[p]!, now: t0); Sched.finished(&all[p]!, now: at(30), transient: true, rateLimited: false, retryAfter: nil) }
    Sched.generalTrigger(&all, now: at(40), reason: "깨어남")
    check(all[.agy]!.blockedUntil == at(90) && all[.agy]!.requestGap == nil, "general trigger: agy keeps its backoff and gets no request")
    check(all[.codex]!.blockedUntil == at(40) && all[.codex]!.requestGap == RefreshPolicy.minGap(.codex) && all[.claude]!.requestGap == RefreshPolicy.minGap(.claude),
          "general trigger: Codex's network backoff is cleared, Codex and Claude are asked")
    check(Sched.decide(all[.codex]!, now: at(40), idle: 180) == .start, "general trigger: Codex retries now (its gap since the start has passed)")

    // Claude debounce: once after the chat goes quiet
    var cd2 = Debouncer.claude(), od = Debouncer.others()
    for i in stride(from: 0.0, through: 60, by: 3) {
        cd2.note([.claude], broad: true, asideSession: true, label: "Aside claude-code", at: at(i))
        od.note([.claude], broad: true, asideSession: true, label: "Aside claude-code", at: at(i))
    }
    check(od.first == nil && od.takeIfDue(now: at(200)) == nil, "debounce: Claude activity doesn't touch the other lane")
    check(cd2.takeIfDue(now: at(70)) == nil && cd2.due() == at(80), "debounce: Claude waits until the chat is quiet for 20 s")
    let cGot = cd2.takeIfDue(now: at(80))!
    check(cGot.specific == [.claude] && cGot.broad.isEmpty && cd2.first == nil && cd2.quiet == 20, "debounce: one Claude request per reply, settings kept")
    var cd3 = Debouncer.claude()
    for i in stride(from: 0.0, through: 400, by: 5) { cd3.note([.claude], broad: false, asideSession: true, label: "Aside claude-code", at: at(i)) }
    check(cd3.due() == at(180), "debounce: a reply that keeps writing asks at most every 3 min")
    var cd4 = Debouncer.claude()
    cd4.note([.codex], broad: false, asideSession: true, label: "Aside openai-codex", at: t0)
    check(cd4.first == nil, "debounce: other services' activity doesn't push Claude's quiet time")
    cd4.note([], broad: true, asideSession: false, label: "Aside", at: t0)
    check(cd4.takeIfDue(now: at(20))?.broad == [.claude], "debounce: Aside state.db alone asks Claude once too, at the broad gap")
    var od2 = Debouncer.others()
    od2.note([], broad: true, asideSession: false, label: "Aside", at: t0)
    check(od2.takeIfDue(now: at(10))?.broad == [.codex, .grok], "debounce: ...and Codex, Grok in their lane (never agy)")

    // Claude login kept in memory
    var tc = TokenCache()
    check(tc.usable(now: t0) == nil, "token cache: empty -> read the keychain")
    tc.store(Usage.Login(access: "tok", expires: at(3600)), now: t0)
    check(tc.usable(now: at(60))?.access == "tok", "token cache: a token valid for an hour is reused")
    check(tc.usable(now: at(3000)) == nil, "token cache: read again 10 min before it expires")
    tc.invalidate()
    check(tc.usable(now: at(60)) == nil, "token cache: a 401 drops it")
    tc.store(Usage.Login(error: "키체인 읽기가 허용되지 않았어요"), now: t0)
    check(tc.usable(now: t0) == nil && tc.login == nil, "token cache: errors are never kept")
    tc.store(Usage.Login(access: "tok2", expires: nil), now: t0)
    check(tc.usable(now: at(899))?.access == "tok2" && tc.usable(now: at(900)) == nil, "token cache: no expiry -> read again after 15 min")
    tc.store(Usage.Login(access: "tok3", expires: at(7200)), now: t0)
    check(tc.usable(now: at(14 * 60))?.access == "tok3" && tc.usable(now: at(15 * 60)) == nil,
          "token cache: a token valid for 2 hours is still read again after 15 min (an account switch shows within 15 min)")
    check(TokenCache.maxAge == 900 && 3600 / TokenCache.maxAge <= 4, "token cache: at most 4 keychain reads an hour while idle")
    // the account generation: a switch drops lookups that began before it
    var who = ClaudeIdentity()
    check(!who.note(nil) && !who.note("claude:AAA") && who.generation == 0, "claude account: the first known account is no change")
    let g0 = who.generation
    check(!who.note("claude:aaa") && !who.note(nil) && who.generation == g0, "claude account: same account (any case) or unknown: same generation")
    check(who.note("claude:BBB") && who.generation == g0 + 1 && who.key == "claude:BBB", "claude account: a switch starts a new generation")
    check(!who.isCurrent(g0) && who.isCurrent(g0 + 1), "claude account: a lookup from before the switch is not current, one after it is")
    check(!who.note("claude:BBB") && who.note("claude:AAA") && who.generation == g0 + 2, "claude account: switching back is another change")

    // AI habit check: a link asks first, 10 min between runs
    check(HabitGate.decide(fromURL: true, running: false, lastRun: nil, now: t0) == .confirm, "habit gate: a link asks first")
    check(HabitGate.decide(fromURL: false, running: false, lastRun: nil, now: t0) == .run, "habit gate: the button runs at once")
    check(HabitGate.decide(fromURL: false, running: false, lastRun: at(-60), now: t0) == .wait(9)
          && HabitGate.decide(fromURL: true, running: false, lastRun: at(-599), now: t0) == .wait(1), "habit gate: 10 min between runs, from either")
    check(HabitGate.decide(fromURL: true, running: false, lastRun: at(-600), now: t0) == .confirm, "habit gate: free again after 10 min")
    check(HabitGate.decide(fromURL: true, running: true, lastRun: nil, now: t0) == .busy, "habit gate: one run at a time")
    check(HabitGate.waitText(9) == "9분 뒤에 다시 돌릴 수 있어요" && HabitGate.confirmTitle == "AI 진단을 돌릴까요?"
          && HabitGate.confirmText == "한도를 조금 써요.", "habit gate: wording")

    // agy logs: only the file of our own run, proven by its exact per-run workspace; never other runs' logs, whatever their age
    let wd = "/var/folders/x/T/UsageGauge-agy/1B6E1F2A-0000-4000-8000-00000000AAAA"
    let heads = ["cli-20261031_000101.log": "I1031 server.go] Creating CLI server backend: workspaceDirs=[/private/var/folders/x/T/UsageGauge-agy/1B6E1F2A-0000-4000-8000-00000000AAAA]",
                 "cli-20261031_000102.log": "I1031 manager.go] Initializing CLI store manager for workspace /Users/me/code/app",
                 "cli-20261031_000103.log": "I1031 server.go] Creating CLI server backend: workspaceDirs=[/var/folders/x/T/UsageGauge-agy/1B6E1F2A-0000-4000-8000-00000000AAAA-other]",
                 "cli-20261031_000104.log": "I1031 manager.go] Initializing CLI store manager for workspace /var/folders/x/T/UsageGauge-agy/1B6E1F2A-0000-4000-8000-00000000AAAA/sub",
                 "cli-20261031_000105.log": "I1031 manager.go] Initializing CLI store manager for workspace /var/folders/x/T/UsageGauge-agy",
                 "cli-20261031_000106.log": "x\nI1031 manager.go] Initializing CLI store manager for workspace /var/folders/x/T/UsageGauge-agy/1B6E1F2A-0000-4000-8000-00000000AAAA\n",
                 "cli-20261031_000107.log": "I1031 server.go] Creating CLI server backend: workspaceDirs=[/Users/me/a /var/folders/x/T/UsageGauge-agy/1B6E1F2A-0000-4000-8000-00000000AAAA]",
                 "cli-20261020_000000.log": "workspace " + wd, "notes.txt": "workspace " + wd, "cli.log": "workspace " + wd]
    let lf: [(name: String, created: Date, modified: Date)] = [
        ("cli-20261031_000101.log", at(1), at(9)), ("cli-20261031_000102.log", at(2), at(9)), ("cli-20261031_000103.log", at(2), at(9)),
        ("cli-20261031_000104.log", at(2), at(9)), ("cli-20261031_000105.log", at(2), at(9)), ("cli-20261031_000106.log", at(3), at(9)),
        ("cli-20261031_000107.log", at(3), at(9)),
        ("cli-20261020_000000.log", at(-8 * 86400), at(-8 * 86400)), ("cli-20261024_000000.log", at(-6 * 86400), at(-6 * 86400)),
        ("notes.txt", at(1), at(1)), ("cli.log", at(1), at(1))]
    let pk = AgyLogs.pick(lf, workDir: wd, runStart: t0, now: at(10)) { heads[$0] ?? "" }
    check(pk == ["cli-20261031_000101.log", "cli-20261031_000106.log", "cli-20261031_000107.log"],
          "agy logs: only files naming exactly this run's workspace (also via /private, in a list) are removed")
    check(!pk.contains("cli-20261031_000103.log") && !pk.contains("cli-20261031_000104.log") && !pk.contains("cli-20261031_000105.log"),
          "agy logs: a longer path, a subfolder or the shared parent folder is not ours")
    check(!pk.contains("cli-20261020_000000.log") && !pk.contains("cli-20261024_000000.log"), "agy logs: old logs of other runs are never pruned")
    check(AgyLogs.pick(lf, workDir: wd + "/", runStart: t0, now: at(10)) { heads[$0] ?? "" } == pk, "agy logs: a trailing slash doesn't change the match")
    let w1 = AgyLogs.newWorkDir(), w2 = AgyLogs.newWorkDir()
    check(w1 != w2 && w1.hasPrefix(AgyLogs.root + "/") && UUID(uuidString: (w1 as NSString).lastPathComponent) != nil, "agy logs: a new uuid workspace every run")
    check(AgyLogs.workspaces("a workspaceDirs=[/p/q /r]\nb for workspace /s/t") == ["/p/q", "/r", "/s/t"], "agy logs: workspace fields parsed whole")
    check(AgyLogs.isCliLog("cli-20261030_234908.log") && !AgyLogs.isCliLog("cli.log") && !AgyLogs.isCliLog("cli-2026.log.bak"), "agy logs: name pattern")

    // log rotation
    let rdir = (NSTemporaryDirectory() as NSString).appendingPathComponent("ug-rot-\(getpid())")
    try? FileManager.default.createDirectory(atPath: rdir, withIntermediateDirectories: true)
    let rlog = rdir + "/menubar.log"
    FileManager.default.createFile(atPath: rlog + ".1", contents: Data("older".utf8))
    FileManager.default.createFile(atPath: rlog, contents: Data("current".utf8))
    Log.rotate(rlog)
    check(!FileManager.default.fileExists(atPath: rlog) && (try? String(contentsOfFile: rlog + ".1", encoding: .utf8)) == "current",
          "log: rotates to menubar.log.1, keeping one old file")
    try? FileManager.default.removeItem(atPath: rdir)

    // activity classification
    let r = ActivityRoots(home: "/h")
    check(ActivityClassifier.classify("/h/.aside/u/0/state.db-wal", r) == .asideState
          && ActivityClassifier.classify("/h/.aside/u/0/state.db", r) == .asideState, "activity: Aside state.db(-wal)")
    check(ActivityClassifier.classify("/h/.aside/u/0/sessions/2026_x/messages.jsonl", r) == .asideSession("/h/.aside/u/0/sessions/2026_x/messages.jsonl"),
          "activity: Aside chat log")
    check(ActivityClassifier.classify("/h/.aside/u/0/sessions/2026_x/tmp/a.png", r) == nil
          && ActivityClassifier.classify("/h/.aside/u/0/memory/x.md", r) == nil
          && ActivityClassifier.classify("/h/.aside/u/0/state.db-shm", r) == nil, "activity: other Aside files ignored")
    check(ActivityClassifier.classify("/h/.codex/sessions/2026/10/30/r.jsonl", r) == .codex
          && ActivityClassifier.classify("/h/.claude/projects/-x/abc.jsonl", r) == .claude
          && ActivityClassifier.classify("/h/.grok/sessions/s1", r) == .grok, "activity: CLI session folders")
    check(ActivityClassifier.classify("/h/.gemini/antigravity-cli/conversations/c1.pb", r) == .agy
          && ActivityClassifier.classify("/h/.gemini/antigravity-cli/cli.log", r) == nil
          && ActivityClassifier.classify("/h/.gemini/antigravity-cli/log/cli-1.log", r) == nil, "activity: agy conversations count, its logs don't")
    check(ActivityClassifier.classify("/h/.gemini/antigravity-cli/brain/b1/x.md", r) == .agy
          && ActivityClassifier.classify("/h/.gemini/antigravity-cli/conversation_summaries.db-wal", r) == nil
          && ActivityClassifier.classify("/h/.gemini/antigravity-cli/updater/update.lock", r) == nil, "activity: agy brain counts; summaries db and updater don't (every run writes them)")
    check(r.excluded.contains("/h/.aside/u/0/memory") && r.excluded.count <= 8 && !r.excluded.contains("/h/.aside/u/0/sessions"),
          "activity: Aside folders that never count are excluded from the watch (at most 8)")
    check(ActivityClassifier.classify("/h/.codexx/sessions/a", r) == nil && ActivityClassifier.classify("/h/.claude/projectsX/a", r) == nil,
          "activity: prefix must be a whole folder")
    check(ActivityClassifier.provider(aside: "claude-code") == .claude && ActivityClassifier.provider(aside: "openai-codex") == .codex
          && ActivityClassifier.provider(aside: "xai-grok-oauth") == .grok && ActivityClassifier.provider(aside: "aside") == nil,
          "activity: Aside provider ids -> services")
    check(ActivityClassifier.lastProviderId("{\"provider\":\"openai-codex\"}\n{\"provider\":\"claude-code\",\"model\":\"m\"}\n{\"role\":\"x\"}") == "claude-code"
          && ActivityClassifier.lastProviderId("{\"role\":\"x\"}") == nil, "activity: last provider in a chat log tail")
    let now2 = t0
    check(freshnessText(now2, now: now2.addingTimeInterval(30)) == "방금 확인" && freshnessText(now2, now: now2.addingTimeInterval(185)) == "3분 전 확인"
          && freshnessText(nil) == nil, "freshness text")
}
print("RESULT \(passed) mac logic tests passed")
