import Foundation

// Claude's login, renewed by Claude Code itself (2026-11-03, "빠릿빠릿하지 않다").
// Claude Code's access token lives about 8 hours and only Claude Code renews it, when it runs. Here Claude is used
// mostly through Aside, which has its own login, so the keychain token sat expired for hours (18 h on 11-02) and
// the menu bar kept an old Claude number. Now, when the token has expired or is about to, the app runs Claude Code
// once, headless: `claude -p` with the smallest model, no tools, no MCP servers, no saved session. Claude Code then
// renews its own login under its own lock, and the app reads the keychain again. The app itself still never writes
// a login or calls the token endpoint. At most once every 20 minutes; each run is one tiny request on the Claude limit.
enum ClaudeRenew {
    static let soon: TimeInterval = 4 * 60       // Claude Code renews only shortly before the expiry
    static let minGap: TimeInterval = 20 * 60    // whatever happens, not more often than this
    static let timeout: TimeInterval = 90

    private static let lock = NSLock()
    private static var lastRun: Date?
    private static var running = false

    // pure (unit tested): renew when the token has expired or expires within `soon`, and the last run is old enough
    static func due(expires: Date?, lastRun: Date?, now: Date) -> Bool {
        guard let e = expires, e.timeIntervalSince(now) <= soon else { return false }
        if let l = lastRun, now.timeIntervalSince(l) < minGap { return false }
        return true
    }

    // Claude Code's command: a GUI app gets a short PATH, so the usual install places are tried too
    static func exe(home: String = Usage.home, path: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        var c = [".local/bin/claude", ".claude/local/claude", ".npm-global/bin/claude"].map { (home as NSString).appendingPathComponent($0) }
        c += ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        c += (path ?? "").split(separator: ":").map { ($0 as NSString).appendingPathComponent("claude") }
        return c.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // Runs Claude Code once if due. Blocks the calling (background) thread for a few seconds. True when it ran.
    @discardableResult
    static func runIfDue(expires: Date?, now: Date = Date()) -> Bool {
        lock.lock()
        if running || !due(expires: expires, lastRun: lastRun, now: now) { lock.unlock(); return false }
        running = true; lastRun = now
        lock.unlock()
        defer { lock.lock(); running = false; lock.unlock() }

        guard let exe = exe() else { Log.write("claude renew: Claude Code not found, can't renew the login"); return false }
        let work = (Paths.appHome as NSString).appendingPathComponent("claude-renew")
        try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-p", "--model", "haiku", "--no-session-persistence", "--strict-mcp-config",
                       "--tools", "", "--disable-slash-commands", "Reply with: ok"]
        p.currentDirectoryURL = URL(fileURLWithPath: work)
        var env = ProcessInfo.processInfo.environment
        // Claude Code files its login under the user's name; with USER unset it looks for an "unknown" item and
        // answers "Not logged in" (seen from an AI shell on 2026-11-03)
        env["USER"] = NSUserName(); env["LOGNAME"] = NSUserName(); env["HOME"] = Usage.home
        env["PATH"] = [(Usage.home as NSString).appendingPathComponent(".local/bin"), "/opt/homebrew/bin", "/usr/local/bin",
                       "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out; p.standardError = out
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        let t0 = Date()
        do { try p.run() } catch { Log.write("claude renew: could not start Claude Code"); return false }
        var collected = Data()
        let reader = DispatchQueue(label: "UsageGauge.claude-renew")
        reader.async { collected = out.fileHandleForReading.readDataToEndOfFile() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 3)
            Log.write("claude renew: Claude Code took longer than \(Int(timeout)) s, stopped")
            return true
        }
        reader.sync {}
        let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
        if p.terminationStatus == 0 {
            Log.write("claude renew: ran Claude Code (\(secs) s)")
        } else {
            // the first line that is not a settings warning, cut short (no tokens are ever printed by `claude -p`)
            let text = String(decoding: collected.prefix(4096), as: UTF8.self)
            let line = text.split(separator: "\n").map(String.init).first { !$0.hasPrefix("Permission allow rule") } ?? ""
            Log.write("claude renew: Claude Code exit \(p.terminationStatus) (\(secs) s): " + String(line.prefix(120)))
        }
        return true
    }
}
