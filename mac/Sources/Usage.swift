import Foundation
import CryptoKit
import Security

// macOS port of UsageGauge.cs `Usage` (Codex / Claude / Grok).
// Reads weekly quota straight from each service, using the login the official tool already saved on this Mac.
// Rules carried over from Windows:
//  - GET only. No OAuth refresh POST, no credential writes. Authentication belongs to the official tools.
//  - 401 and 403 are reported separately; a 401 with an already-expired token means "wait for the tool to refresh".
//  - On 401, the login is re-read once and the request retried only if the official tool already changed the token.
//  - Tokens are never logged or written anywhere; only a one-way hash is kept in memory.

final class UsageWindow {
    var key: String
    var used: Double
    var seconds: Double = .nan
    var reset: Date?
    init(key: String, used: Double, seconds: Double = .nan, reset: Date?) {
        self.key = key; self.used = used; self.seconds = seconds; self.reset = reset
    }
}

final class Quota {
    var name: String = ""
    var ok = false
    var remaining: Double = 0
    var resetsAt: Date?
    var stale = false          // failing AND last good values are old
    var failing = false        // most recent fetch failed
    var lastOk: Date?
    var error: String?         // Korean, shown in the menu
    var transient = false      // network / rate limit / server: heals by itself
    var noLogin = false        // the official tool has no saved login on this Mac
    var notInstalled = false   // Antigravity: agy CLI not found
    // Which login produced this value. accountKey is a stable account id; credKey is a one-way hash of the
    // access token actually sent (in memory only), used when the account id itself is unavailable.
    var account: String?, accountKey: String?, credKey: String?
    var extra: String?
    var accountChanged: Date?
    var windows: [UsageWindow] = []

    static func fail(_ msg: String, transient: Bool = false) -> Quota {
        let q = Quota(); q.error = msg; q.transient = transient; return q
    }
    static func noLoginFound() -> Quota {
        let q = Quota(); q.error = "로그인 없음"; q.noLogin = true; return q
    }
}

enum Usage {
    static let timeout: TimeInterval = 12
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    private static let gate = NSLock()

    static func envDir(_ variable: String, _ fallback: String) -> String {
        if let v = ProcessInfo.processInfo.environment[variable]?.trimmingCharacters(in: .whitespaces), !v.isEmpty { return v }
        return (home as NSString).appendingPathComponent(fallback)
    }
    static var codexAuth: String { (envDir("CODEX_HOME", ".codex") as NSString).appendingPathComponent("auth.json") }
    static var claudeCredFile: String { (envDir("CLAUDE_CONFIG_DIR", ".claude") as NSString).appendingPathComponent(".credentials.json") }
    static var grokAuth: String { (envDir("GROK_HOME", ".grok") as NSString).appendingPathComponent("auth.json") }

    // ---------- Codex (ChatGPT login of the Codex CLI / app) ----------
    static func codex() -> Quota {
        guard let auth = readJson(codexAuth), let tokens = auth["tokens"] as? [String: Any],
              let access = str(tokens, "access_token") else { return .noLoginFound() }
        let accountId = str(tokens, "account_id")
        let email = str(jwtClaims(str(tokens, "id_token")), "email")
        let key = accountId != nil ? "codex:" + accountId! : email != nil ? "codex-email:" + email!.lowercased() : nil
        return tag(codexWith(access, accountId), email, key, hash(access))
    }
    private static func codexWith(_ access: String, _ account: String?) -> Quota {
        var h = ["Authorization": "Bearer " + access]
        if let a = account { h["ChatGPT-Account-Id"] = a }
        let (status, body) = http("https://chatgpt.com/backend-api/wham/usage", headers: h)
        return codexResult(status, body)
    }
    static func codexResult(_ status: Int, _ body: Data?) -> Quota {
        if status == 401 || status == 403 { return .fail(authError(status)) }
        if status != 200 { return httpError(status) }
        guard let j = parse(body), let rl = j["rate_limit"] as? [String: Any] else { return .fail("응답 형식이 바뀌었어요") }
        var weekly: Quota?; var extra: [String] = []; var wins: [UsageWindow] = []
        for key in ["primary_window", "secondary_window"] {
            guard let w = rl[key] as? [String: Any] else { continue }
            let used = num(w, "used_percent"), secs = num(w, "limit_window_seconds")
            if used.isNaN { continue }
            let reset = w["reset_at"].flatMap { parseTime($0) }
            wins.append(UsageWindow(key: key, used: used, seconds: secs, reset: reset))
            if secs != 604800 { extra.append(windowName(secs) + " " + percentText(used) + "%"); continue }   // gauge = the 7-day window
            if weekly != nil { continue }
            weekly = ok(100 - used)
            if weekly!.ok { weekly!.resetsAt = reset }
        }
        guard let q = weekly else { return .fail("주간 한도를 찾지 못했어요") }
        if !q.ok { return q }
        if !extra.isEmpty { q.extra = extra.joined(separator: ", ") }
        q.windows = wins
        return q
    }
    static func windowName(_ secs: Double) -> String {
        if secs == 18000 { return "5시간 사용" }
        if secs == 86400 { return "1일 사용" }
        if !secs.isNaN && secs > 0 { return "\(Int((secs / 3600).rounded()))시간 사용" }
        return "다른 한도 사용"
    }

    // ---------- login identity ----------
    static func tag(_ q: Quota, _ account: String?, _ accountKey: String?, _ credKey: String?) -> Quota {
        q.account = account; q.accountKey = accountKey; q.credKey = credKey; return q
    }
    // same as C#: first 12 bytes of SHA-256, upper-case hex
    static func hash(_ secret: String?) -> String? {
        guard let s = secret, !s.isEmpty else { return nil }
        let d = SHA256.hash(data: Data(s.utf8))
        return d.prefix(12).map { String(format: "%02X", $0) }.joined()
    }
    // Display-only decode of the id_token payload (no signature check: never used for auth).
    static func jwtClaims(_ jwt: String?) -> [String: Any]? {
        guard let jwt = jwt, !jwt.isEmpty else { return nil }
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var b = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let data = Data(base64Encoded: b) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    // Claude's credentials have no account id, so ask the official profile endpoint with the same token
    // (GET, read-only). Cached per token hash so it runs once per login/refresh, not every poll.
    private static var claudeProfiles: [String: [String?]] = [:]
    static func cachedClaudeProfile(_ credKey: String) -> [String?]? {
        gate.lock(); defer { gate.unlock() }; return claudeProfiles[credKey]
    }
    private static func claudeProfile(_ access: String, _ credKey: String) -> [String?]? {
        if let hit = cachedClaudeProfile(credKey) { return hit }
        let (st, body) = http("https://api.anthropic.com/api/oauth/profile",
                              headers: ["Authorization": "Bearer " + access, "anthropic-beta": "oauth-2025-04-20"])
        guard st == 200, let j = parse(body), let acct = j["account"] as? [String: Any] else { return nil }
        let uuid = str(acct, "uuid"), email = str(acct, "email")
        if uuid == nil && email == nil { return nil }
        let r: [String?] = [uuid != nil ? "claude:" + uuid! : "claude-email:" + email!.lowercased(), email]
        gate.lock(); if claudeProfiles.count > 16 { claudeProfiles.removeAll() }; claudeProfiles[credKey] = r; gate.unlock()
        return r
    }
    // 401 with a token whose own expiry has passed: the official tool refreshes it the next time it runs.
    static func rejected(_ service: String, _ status: Int, _ expires: Date?) -> String {
        if status == 401, let e = expires, e <= Date() { return "토큰 갱신 대기(401): \(service)를 한 번 열어 주세요" }
        return authError(status)
    }

    // ---------- Claude (Claude Code login) ----------
    struct Login { var access: String?; var error: String?; var account: String?; var accountKey: String?; var expires: Date?; var noLogin = false }

    // Keychain access denied by the user: don't ask again on every poll; "새로고침" clears it.
    static var keychainDenied = false

    // Claude Code on macOS keeps its login in the login keychain ("Claude Code-credentials"); some setups use the
    // file ~/.claude/.credentials.json instead. Both are read only. The keychain item wins when it exists.
    static func readClaude() -> Login? {
        let kc = ClaudeKeychain.read()
        switch kc {
        case .found(let data):
            if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return claudeLogin(root) }
            return Login(error: "키체인 로그인 정보를 읽지 못했어요")
        case .denied:
            keychainDenied = true
            return Login(error: "키체인 읽기가 허용되지 않았어요 (새로고침에서 다시 묻기)")
        case .notFound, .skipped:
            break
        case .error(let s):
            if !FileManager.default.fileExists(atPath: claudeCredFile) { return Login(error: "키체인 오류 \(s)") }
        }
        guard let root = readJson(claudeCredFile) else {
            if case .skipped = kc { return Login(error: "키체인 읽기가 허용되지 않았어요 (새로고침에서 다시 묻기)") }
            return nil
        }
        return claudeLogin(root)
    }
    private static func claudeLogin(_ root: [String: Any]) -> Login? {
        guard let oauth = root["claudeAiOauth"] as? [String: Any] else { return nil }
        let ms = num(oauth, "expiresAt")
        return Login(access: str(oauth, "accessToken"), expires: ms.isNaN || ms <= 0 ? nil : Date(timeIntervalSince1970: ms / 1000))
    }

    static func claude() -> Quota {
        var err: String?; var used: Login?; var sawLogin = false
        let (st, body) = authedGet("https://api.anthropic.com/api/oauth/usage", "anthropic-beta", "oauth-2025-04-20") {
            let l = readClaude()
            if l != nil { sawLogin = true }
            guard let login = l, login.error == nil, let a = login.access else { err = l?.error; return nil }
            used = login; return a
        }
        if st < 0 && err == nil && !sawLogin { return .noLoginFound() }
        let cred = hash(used?.access)
        let q = claudeResult(parse(body), st, err, used)
        var who: [String?]?
        if let c = cred, let u = used?.access {
            who = q.ok ? claudeProfile(u, c) : cachedClaudeProfile(c)
        }
        return tag(q, who?[1] ?? nil, who?[0] ?? nil, cred)
    }
    static func claudeResult(_ j: [String: Any]?, _ st: Int, _ err: String?, _ used: Login?) -> Quota {
        if st < 0 { return .fail(err ?? "로그인 없음") }
        if st == 401 || st == 403 { return .fail(rejected("Claude", st, used?.expires)) }
        if st != 200 { return httpError(st) }
        guard let j = j, let w = j["seven_day"] as? [String: Any] else { return .fail("응답 형식이 바뀌었어요") }
        let used7 = num(w, "utilization")
        if used7.isNaN { return .fail("주간 한도를 찾지 못했어요") }
        let q = ok(100 - used7)
        if !q.ok { return q }
        q.resetsAt = w["resets_at"].flatMap { parseTime($0) }
        q.windows.append(UsageWindow(key: "seven_day", used: used7, reset: q.resetsAt))
        var extra: [String] = []
        for k in ["five_hour", "seven_day_opus", "seven_day_sonnet"] {
            guard let x = j[k] as? [String: Any] else { continue }
            let u = num(x, "utilization"); if u.isNaN { continue }
            q.windows.append(UsageWindow(key: k, used: u, reset: x["resets_at"].flatMap { parseTime($0) }))
            let label = k == "five_hour" ? "5시간 사용" : k == "seven_day_opus" ? "주간 Opus 사용" : "주간 Sonnet 사용"
            extra.append(label + " " + percentText(u) + "%")
        }
        if !extra.isEmpty { q.extra = extra.joined(separator: ", ") }
        return q
    }

    // ---------- Grok (Grok CLI login) ----------
    static func readGrok() -> Login? {
        guard let root = readJson(grokAuth) else { return nil }
        var entry: [String: Any]?; var count = 0
        for (k, v) in root where k.hasPrefix("https://auth.x.ai::") {
            if let d = v as? [String: Any] { count += 1; entry = d }
        }
        if count != 1 { return count > 1 ? Login(error: "auth.json에 Grok 계정이 여러 개라 어느 것이 쓰이는지 알 수 없어요") : nil }
        let e = entry!
        let uid = str(e, "user_id") ?? str(e, "principal_id")
        var label = str(e, "email") ?? str(e, "first_name")
        if label == nil, let u = uid { label = "ID " + String(u.prefix(8)) }
        var exp: Date?
        if let es = str(e, "expires_at") { exp = parseTime(es) }
        return Login(access: str(e, "key"), account: label, accountKey: uid == nil ? nil : "grok:" + uid!, expires: exp)
    }
    static func grok() -> Quota {
        var err: String?; var used: Login?; var sawLogin = false
        let (st, body) = authedGet("https://cli-chat-proxy.grok.com/v1/billing?format=credits", "x-xai-token-auth", "xai-grok-cli") {
            let l = readGrok()
            if l != nil { sawLogin = true }
            guard let login = l, login.error == nil, let a = login.access else { err = l?.error; return nil }
            used = login; return a
        }
        if st < 0 && err == nil && !sawLogin { return .noLoginFound() }
        let q = grokResult(parse(body), st, err, used)
        guard let u = used else { return q }
        return tag(q, u.account, u.accountKey, hash(u.access))
    }
    static func grokResult(_ j: [String: Any]?, _ st: Int, _ err: String?, _ login: Login?) -> Quota {
        if st < 0 { return .fail(err ?? "로그인 없음") }
        if st == 401 || st == 403 { return .fail(rejected("Grok", st, login?.expires)) }
        if st != 200 { return httpError(st) }
        guard let j = j, let c = j["config"] as? [String: Any] else { return .fail("응답 형식이 바뀌었어요") }
        guard let period = c["currentPeriod"] as? [String: Any], str(period, "type") == "USAGE_PERIOD_TYPE_WEEKLY" else {
            return .fail("주간 기간을 찾지 못했어요")
        }
        var used = 0.0                                                  // the field is omitted while nothing is used
        if let v = c["creditUsagePercent"], !(v is NSNull) {
            used = num(c, "creditUsagePercent"); if used.isNaN { return .fail("사용량 값이 숫자가 아니에요") }
        }
        let q = ok(100 - used)
        if !q.ok { return q }
        q.resetsAt = period["end"].flatMap { parseTime($0) }
        q.windows.append(UsageWindow(key: "weekly", used: used, reset: q.resetsAt))
        return q
    }

    // GET only. On 401, re-read once and retry only if the official tool already changed the token.
    // status -1 = no login was readable.
    static func authedGet(_ url: String, _ hName: String, _ hValue: String, token: () -> String?) -> (Int, Data?) {
        var status = -1; var previous: String?
        for attempt in 0..<2 {
            guard let access = token() else { if attempt > 0 { status = 401 }; return (status, nil) }
            if attempt > 0 && access == previous { return (status, nil) }
            previous = access
            let (st, body) = http(url, headers: ["Authorization": "Bearer " + access, hName: hValue])
            status = st
            if st != 401 { return (st, body) }
        }
        return (status, nil)
    }

    // ---------- helpers ----------
    static func ok(_ remaining: Double) -> Quota {
        // over-quota (used > 100%) shows as 0% left; only absurd values are rejected
        if remaining.isNaN || remaining.isInfinite || remaining < -1000 || remaining > 100.5 { return .fail("값이 올바르지 않아요") }
        let q = Quota(); q.ok = true; q.remaining = max(0, min(100, remaining)); return q
    }
    static func authError(_ status: Int) -> String {
        status == 401 ? "로그인 만료(401): 공식 도구로 다시 로그인" : "접근 거부(403): 계정 권한 확인"
    }
    static func httpError(_ status: Int) -> Quota {
        if status <= 0 { return .fail("시간 초과(네트워크)", transient: true) }
        if status == 429 { return .fail("요청 제한(429), 곧 다시 시도", transient: true) }
        if status >= 500 { return .fail("서버 오류 \(status)", transient: true) }
        return .fail("요청 실패(HTTP \(status))")
    }
    static func remainingNumber(_ v: Double) -> String {
        if v > 0 && v < 1 { return "<1" }
        if v > 99 && v < 100 { return ">99" }
        return String(Int(v.rounded()))
    }
    static func percentText(_ v: Double) -> String {
        if v > 0 && v < 0.01 { return "<0.01" }
        if v > 99.99 && v < 100 { return ">99.99" }
        let f = NumberFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.maximumFractionDigits = 2; f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    // One GET. status: HTTP code, or 0 on network error / timeout. Ephemeral session: no cookies, no cache on disk.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout; c.timeoutIntervalForResource = timeout
        c.httpCookieAcceptPolicy = .never; c.httpShouldSetCookies = false; c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()
    static func http(_ url: String, headers: [String: String]) -> (Int, Data?) {
        guard let u = URL(string: url) else { return (0, nil) }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("UsageGauge", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let sem = DispatchSemaphore(value: 0)
        var status = 0; var out: Data?
        let task = session.dataTask(with: req) { data, resp, _ in
            if let h = resp as? HTTPURLResponse { status = h.statusCode; out = data.map { $0.count > 512 * 1024 ? $0.prefix(512 * 1024) : $0 } }
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout + 2) == .timedOut { task.cancel(); return (0, nil) }
        return (status, out)
    }
    static func parse(_ data: Data?) -> [String: Any]? {
        guard let d = data, !d.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
    // read-only; the owning app may be rewriting it right now, so retry briefly
    static func readJson(_ path: String) -> [String: Any]? {
        for i in 0..<3 {
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            if let h = FileHandle(forReadingAtPath: path) {
                let d = h.readDataToEndOfFile(); try? h.close()
                if let j = parse(d) { return j }
            }
            if i < 2 { Thread.sleep(forTimeInterval: 0.15) }
        }
        return nil
    }
    static func str(_ d: [String: Any]?, _ key: String) -> String? {
        guard let v = d?[key], !(v is NSNull) else { return nil }
        let s = "\(v)"; return s.isEmpty ? nil : s
    }
    static func num(_ d: [String: Any]?, _ key: String) -> Double {
        guard let v = d?[key] else { return .nan }
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = v as? String, let x = Double(s.trimmingCharacters(in: .whitespaces)) { return x }
        return .nan
    }
    static func parseTime(_ v: Any) -> Date? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            var x = n.doubleValue
            if x > 1e11 { x /= 1000 }                                     // milliseconds -> seconds
            if x.isNaN || x <= 0 || x > 4102444800 { return nil }         // missing or beyond year 2100
            return Date(timeIntervalSince1970: x)
        }
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let x = Double(s) { return parseTime(NSNumber(value: x)) }
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: s) { return d }
        // no zone: assume UTC (same as the Windows parser)
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            df.dateFormat = fmt; if let d = df.date(from: s) { return d }
        }
        return nil
    }
}

// Read-only access to Claude Code's keychain item. Read through /usr/bin/security first: Claude Code reads its own item
// that way, so the tool is already on the item's access list and the read never shows a macOS "allow access" prompt,
// even after this app is rebuilt. The secret is kept in memory only and never logged. Only when the tool fails
// (missing, timeout, unexpected exit) does it fall back to the Security API, whose first read can prompt; existence is
// checked first with attributes only, which never prompts, so a Mac without a Claude login never sees a prompt.
enum ClaudeKeychain {
    enum Result { case found(Data), notFound, denied, skipped, error(OSStatus) }
    static let service = "Claude Code-credentials"
    static var usedFallback = false   // tests and the log line: whether the last read needed the Security API

    static func read() -> Result {
        switch SecurityTool.findGenericPassword(service: service) {
        case .found(let d): usedFallback = false; return .found(d)
        case .notFound: usedFallback = false; return .notFound
        case .failed(let why):
            usedFallback = true
            Log.write("claude keychain: security tool \(why), using the Security API")
            return readWithAPI()
        }
    }
static func exists() -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecMatchLimit as String: kSecMatchLimitOne,
                                kSecReturnAttributes as String: true]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }
    static func readWithAPI() -> Result {
        if !exists() { return .notFound }
        if Usage.keychainDenied { return .skipped }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecMatchLimit as String: kSecMatchLimitOne,
                                kSecReturnData as String: true]
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecSuccess, let d = out as? Data { return .found(d) }
        if s == errSecItemNotFound { return .notFound }
        if s == errSecUserCanceled || s == errSecAuthFailed || s == errSecInteractionNotAllowed { return .denied }
        return .error(s)
    }
}

// Runs /usr/bin/security find-generic-password -s <service> -w. stdout is read into memory only (never logged or
// written anywhere); stderr is discarded. Exit 44 means no such item. Stops the tool after the timeout (10 s).
enum SecurityTool {
    enum Outcome { case found(Data), notFound, failed(String) }
    static let path = "/usr/bin/security"

    static func findGenericPassword(service: String, account: String? = nil, timeout: TimeInterval = 10) -> Outcome {
        var args = ["find-generic-password", "-s", service]
        if let a = account { args += ["-a", a] }
        args.append("-w")
        let r = run(path, args, timeout: timeout)
        switch r.status {
        case .timedOut: return .failed("timeout")
        case .launchFailed: return .failed("not started")
        case .exited(0):
            guard let d = decode(r.stdout) else { return .failed("empty output") }
            return .found(d)
        case .exited(44): return .notFound
        case .exited(let c): return .failed("exit \(c)")
        }
    }

    enum Status: Equatable { case exited(Int32), timedOut, launchFailed }
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> (status: Status, stdout: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return (.launchFailed, Data()) }
        // read while the tool runs, so a full pipe never blocks it
        var data = Data()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async { data = out.fileHandleForReading.readDataToEndOfFile(); reader.leave() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 1)
            return (.timedOut, Data())
        }
        _ = reader.wait(timeout: .now() + 2)
        return (.exited(p.terminationStatus), data)
    }

    // -w prints the secret and a newline; secrets that are not printable text come out as hex
    static func decode(_ raw: Data) -> Data? {
        var d = raw
        while let last = d.last, last == 0x0A || last == 0x0D { d.removeLast() }
        if d.isEmpty { return nil }
        if (try? JSONSerialization.jsonObject(with: d)) == nil, d.count % 2 == 0,
           d.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) || (0x41...0x46).contains($0) }) {
            var bytes = [UInt8](); bytes.reserveCapacity(d.count / 2)
            var i = d.startIndex
            while i < d.endIndex {
                guard let b = UInt8(String(decoding: d[i..<d.index(i, offsetBy: 2)], as: UTF8.self), radix: 16) else { return d }
                bytes.append(b); i = d.index(i, offsetBy: 2)
            }
            return Data(bytes)
        }
        return d
    }
}
