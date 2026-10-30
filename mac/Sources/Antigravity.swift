import Foundation

// Antigravity: the official CLI's own `/usage` slash command (no model call, no tokens), same as Windows.
enum Antigravity {
    static let cliTimeout: TimeInterval = 30
    static let maxOut = 256 * 1024
    // two items like Windows: the Gemini 4 Argon pool, and the rest of Antigravity (Gemini general + Claude, GPT)
    static let geminiName = "Gemini 4 Argon", otherName = "Antigravity(Gemini, Claude, GPT)"

    static func findAgy() -> String? {
        let home = Usage.home
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        // the app starts with a minimal PATH: also look where installers put CLIs
        dirs += [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", home + "/.antigravity/bin", home + "/.agy/bin"]
        for d in dirs where !d.trimmingCharacters(in: .whitespaces).isEmpty {
            let p = (d as NSString).appendingPathComponent("agy")
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func notInstalled() -> [Quota] {
        let q = Quota(); q.name = "Antigravity"; q.error = "설치 안 됨"; q.notInstalled = true
        return [q]
    }

    // returns [Gemini 4 Argon, rest of Antigravity]; or a single "설치 안 됨" row when agy is missing
    static func fetch() -> [Quota] {
        guard let agy = findAgy() else { return notInstalled() }
        let work = (NSTemporaryDirectory() as NSString).appendingPathComponent("UsageGauge-agy")
        try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let (fail, parsed) = runCli(agy, ["-p", "/usage", "--output-format", "json", "--print-timeout", "25s"], work)
        func both(_ m: String, transient: Bool = false) -> [Quota] {
            let a = Quota.fail(m, transient: transient), b = Quota.fail(m, transient: transient)
            a.name = geminiName; b.name = otherName; return [a, b]
        }
        if let f = fail { return both(f, transient: f.hasPrefix("시간 초과") || f.hasPrefix("빈 응답")) }
        var buckets: [String: [String: Any]] = [:]
        guard let cmd = parsed?["command"] as? [String: Any], let data = cmd["data"] as? [String: Any],
              let groups = data["groups"] as? [Any] else { return both("agy 응답 형식이 바뀌었어요") }
        for go in groups {
            guard let g = go as? [String: Any], let bs = g["buckets"] as? [Any] else { continue }
            for bo in bs { if let b = bo as? [String: Any], let id = Usage.str(b, "id") { buckets[id] = b } }
        }
        DashboardFeed.rememberAntigravity(buckets)
        return split(buckets)
    }

    // Gemini 4 Argon = buckets named argon (or, as on Windows, any gemini-*-weekly model pool other than the
    // general one); everything else (gemini-weekly/5h, 3p-weekly/5h) is the Antigravity item.
    static func isArgon(_ id: String) -> Bool {
        let l = id.lowercased()
        return l.contains("argon") || (l.hasPrefix("gemini-") && l.hasSuffix("-weekly") && l != "gemini-weekly")
    }
    static func split(_ buckets: [String: [String: Any]]) -> [Quota] {
        let ids = buckets.keys.sorted()
        return [group(buckets, ids.filter { isArgon($0) }, geminiName), group(buckets, ids.filter { !isArgon($0) }, otherName)]
    }

    // one item from several buckets: the weekly value is the lowest weekly bucket (tie: the later reset); every
    // weekly and 5-hour bucket is kept as a window, so the menu bar shows the one that binds right now.
    static func group(_ buckets: [String: [String: Any]], _ ids: [String], _ name: String) -> Quota {
        func err(_ m: String) -> Quota { let q = Quota.fail(m); q.name = name; return q }
        if ids.isEmpty { return err("한도를 찾지 못했어요") }
        var wins: [UsageWindow] = [], weekly: (rem: Double, reset: Date?)?, firstErr: String?
        for id in ids {
            guard let b = buckets[id] else { continue }
            let key: String
            switch Usage.str(b, "window") ?? "weekly" {
            case "weekly": key = "weekly"
            case "5h": key = "five_hour"
            default: firstErr = firstErr ?? "주간 한도가 아니에요"; continue
            }
            let frac = Usage.num(b, "remaining_fraction")
            if frac.isNaN { firstErr = firstErr ?? "남은 양이 없어요"; continue }
            if frac < -0.005 || frac > 1.005 { firstErr = firstErr ?? "값이 올바르지 않아요"; continue }
            let rem = max(0, min(100, frac * 100)), reset = b["reset_time"].flatMap { Usage.parseTime($0) }
            wins.append(UsageWindow(key: key, used: 100 - rem, reset: reset))
            if key == "weekly" {
                if let w = weekly {
                    if rem < w.rem - 0.0001 || (abs(rem - w.rem) <= 0.0001 && (reset ?? .distantPast) > (w.reset ?? .distantPast)) { weekly = (rem, reset) }
                } else { weekly = (rem, reset) }
            }
        }
        guard let w = weekly else { return err(firstErr ?? "주간 한도가 아니에요") }
        let q = Quota(); q.name = name; q.ok = true; q.remaining = w.rem; q.resetsAt = w.reset; q.windows = wins
        return q
    }

    // Runs the CLI with one hard deadline. Returns (failure text or nil, parsed first JSON line).
    static func runCli(_ exe: String, _ args: [String], _ workDir: String) -> (String?, [String: Any]?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: workDir)
        p.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        let lock = NSLock(); var out = Data(); var overflow = false
        let outDone = DispatchSemaphore(value: 0), exited = DispatchSemaphore(value: 0)
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; outDone.signal(); return }
            lock.lock(); if out.count < maxOut { out.append(d) } else { overflow = true }; lock.unlock()
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in if h.availableData.isEmpty { h.readabilityHandler = nil } }
        p.terminationHandler = { _ in exited.signal() }
        let started = Date()
        do { try p.run() } catch { return ("agy를 실행하지 못했어요", nil) }
        if exited.wait(timeout: .now() + cliTimeout) == .timedOut {
            p.terminate(); kill(p.processIdentifier, SIGKILL)
            outPipe.fileHandleForReading.readabilityHandler = nil
            return ("시간 초과(\(Int(Date().timeIntervalSince(started)))초)", nil)
        }
        // a leftover child can keep the pipe open; don't wait for it long
        _ = outDone.wait(timeout: .now() + 1.5)
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); let text = String(decoding: out, as: UTF8.self); let over = overflow; lock.unlock()
        if over { return ("응답이 너무 커요", nil) }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ("빈 응답(\(Int(Date().timeIntervalSince(started)))초)", nil) }
        // agy prints one JSON object (sometimes followed by extra lines): parse the first line that is JSON
        var parsed: [String: Any]?
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{") else { continue }
            if let j = (try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [String: Any] { parsed = j; break }
        }
        guard let dict = parsed else { return ("빈 응답(종료 코드 \(p.terminationStatus))", nil) }
        if let st = Usage.str(dict, "status"), st != "SUCCESS" { return (sanitize(Usage.str(dict, "error") ?? st), nil) }
        return (nil, dict)
    }

    static func sanitize(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "[A-Za-z0-9_\\-.=+/]{32,}", with: "…", options: .regularExpression)   // anything token-like
        t = t.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return t.count > 300 ? String(t.prefix(300)) + "…" : t
    }
}
