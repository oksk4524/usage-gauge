import Foundation

// Paths shared with the collector (tools/usage-insights-collector/refresh-dashboard.cjs, darwin branch).
enum Paths {
    static let appHome = (Usage.home as NSString).appendingPathComponent("Library/Application Support/UsageGauge")
    static let dashboard = (appHome as NSString).appendingPathComponent("dashboard")
    static let data = (dashboard as NSString).appendingPathComponent("data")
    static let page = (dashboard as NSString).appendingPathComponent("usage-gauge.html")
    static let refreshScript = (dashboard as NSString).appendingPathComponent("app/tools/usage-insights-collector/refresh-dashboard.cjs")
    static let nodePathFile = (dashboard as NSString).appendingPathComponent("node-path")
    static let log = (appHome as NSString).appendingPathComponent("menubar.log")
}

// Hands the latest readings to the local dashboard, like DashboardFeed in UsageGauge.cs:
// - only when the dashboard is set up (its data folder exists); never creates it
// - whole-file replace, one line per service
// - masked account label and a one-way account key only; no tokens, no emails, no raw responses
enum DashboardFeed {
    private static let lock = NSLock()
    private static var agBuckets: [[String: Any]]?; private static var agAt = Date()
    private static var lastLimits: String?, lastAg: String?

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: d)
    }

    static func rememberAntigravity(_ buckets: [String: [String: Any]]) {
        var list: [[String: Any]] = []
        for k in buckets.keys.sorted() {
            if list.count >= 16 { break }
            let v = buckets[k]!
            let frac = Usage.num(v, "remaining_fraction"); if frac.isNaN { continue }
            var b: [String: Any] = [:]
            b["id"] = k.count > 64 ? String(k.prefix(64)) : k
            b["window"] = Usage.str(v, "window") == "weekly" ? "weekly" : "unknown"
            b["remaining_percent"] = max(0, min(100, frac * 100))
            if let r = v["reset_time"].flatMap({ Usage.parseTime($0) }) { b["reset_iso"] = iso(r) }
            list.append(b)
        }
        lock.lock(); agBuckets = list; agAt = Date(); lock.unlock()
    }

    static func json(_ o: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    // qs: Codex, Claude, Grok in that order
    static func limitsText(_ qs: [Quota]) -> String {
        var sb = ""
        let services = ["Codex", "Claude", "Grok"]
        for i in 0..<min(3, qs.count) {
            let q = qs[i]
            var row: [String: Any] = ["service": services[i]]
            if !q.ok || q.windows.isEmpty {
                if q.error == nil && !q.ok { continue }   // not polled yet
                row["capturedAt"] = iso(Date()); row["status"] = "unavailable"
            } else {
                row["capturedAt"] = iso(q.lastOk ?? Date())
                row["status"] = "ok"; row["source"] = "widget"
                var data: [String: Any] = [:]
                for w in q.windows {
                    if w.used.isNaN { continue }
                    let used = max(0, min(100, w.used))
                    if i == 2 { data["used_percent"] = used; if let r = w.reset { data["reset_iso"] = iso(r) }; break }
                    var d: [String: Any] = ["used_percent": used]
                    if i == 0 {
                        if !w.seconds.isNaN { d["window_seconds"] = w.seconds }
                        if let r = w.reset { d["reset_at"] = Int64(r.timeIntervalSince1970) }
                    } else if let r = w.reset { d["reset_iso"] = iso(r) }
                    data[w.key] = d
                }
                row["data"] = data
                if let k = q.accountKey {
                    let key: Any = Usage.hash(k) ?? NSNull(), label: Any = mask(q.account) ?? NSNull()
                    row["account"] = ["key": key, "label": label]
                }
                else { row["account"] = NSNull() }
            }
            sb += json(row) + "\n"
        }
        return sb
    }
    static func antigravityText() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let b = agBuckets else { return nil }
        return json(["service": "Antigravity", "status": "ok", "source": "widget", "capturedAt": iso(agAt), "usage_buckets": b]) + "\n"
    }

    // "ab***@example.com": two characters and the domain, nothing else
    static func mask(_ s0: String?) -> String? {
        guard var s = s0, !s.isEmpty else { return nil }
        s = s.trimmingCharacters(in: .whitespaces)
        let at = s.firstIndex(of: "@")
        var head = at.map { String(s[..<$0]) } ?? s
        if at == s.startIndex { head = s }
        head = String(head.prefix(2)).replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "@", with: "")
        if head.isEmpty || head.contains(" ") || head.contains("\t") { return nil }
        var dom = ""
        if let a = at, a != s.startIndex { dom = String(s[a...]) }
        if !dom.isEmpty && dom.range(of: "^@[A-Za-z0-9.-]{1,100}$", options: .regularExpression) == nil { dom = "" }
        return head + "***" + dom
    }

    static func write(_ qs: [Quota]) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: Paths.data, isDirectory: &isDir), isDir.boolValue else { return }
        let limits = limitsText(qs), ag = antigravityText()
        if !limits.isEmpty && limits != lastLimits { if replace((Paths.data as NSString).appendingPathComponent("limits.jsonl"), limits) { lastLimits = limits } }
        if let a = ag, a != lastAg { if replace((Paths.data as NSString).appendingPathComponent("antigravity-limits.jsonl"), a) { lastAg = a } }
    }
    // whole-file replace: a reader sees the old or the new file, never half of one
    private static func replace(_ file: String, _ text: String) -> Bool {
        let tmp = file + ".widget-tmp"
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: tmp))
            if rename(tmp, file) != 0 { try? FileManager.default.removeItem(atPath: tmp); return false }
            return true
        } catch { Log.write("dashboard feed: " + error.localizedDescription); return false }
    }
}

enum Log {
    static var enabled = true   // tests turn this off so they never touch the real log
    static let maxSize = 256 * 1024
    // past 256 KB the log becomes menubar.log.1 (the one before that is dropped) and a new log starts
    static func rotate(_ path: String) {
        let fm = FileManager.default, old = path + ".1"
        try? fm.removeItem(atPath: old)
        if (try? fm.moveItem(atPath: path, toPath: old)) == nil { try? fm.removeItem(atPath: path) }
    }
    static func write(_ s: String) {
        guard enabled else { return }
        let line = DashboardFeed.iso(Date()) + " " + s + "\n"
        try? FileManager.default.createDirectory(atPath: Paths.appHome, withIntermediateDirectories: true)
        if let h = FileHandle(forWritingAtPath: Paths.log) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            if let size = (try? FileManager.default.attributesOfItem(atPath: Paths.log))?[.size] as? Int, size > maxSize { rotate(Paths.log) }
        } else {
            FileManager.default.createFile(atPath: Paths.log, contents: Data(line.utf8))
        }
    }
}
