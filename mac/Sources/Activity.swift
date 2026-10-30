import Foundation
import CoreServices
import Network

// Sees AI use as it happens, from the files the tools write (FSEvents; nothing is read except the tail of an
// Aside chat log, to learn which service that chat runs on). Only the paths below are looked at:
//   ~/.aside/u/0/state.db(-wal), ~/.aside/u/0/sessions/*/messages.jsonl   Aside chats (provider field -> service)
//   ~/.codex/sessions, ~/.claude/projects, ~/.grok/sessions                 the official CLIs' session logs
//   ~/.gemini/antigravity-cli (conversations, brain)                         agy
// Roots that don't exist yet are picked up by a re-check every few minutes. Aside folders that never matter here
// (memory, projects, skills, caches) are excluded from the watch, so their writes don't wake the app.

enum ActivitySource: Equatable { case asideSession(String), asideState, codex, claude, grok, agy }

struct ActivityRoots: Equatable {
    var aside, codex, claude, grok, agy: String
    init(home: String, codexHome: String? = nil, claudeHome: String? = nil, grokHome: String? = nil) {
        func j(_ a: String, _ b: String) -> String { (a as NSString).appendingPathComponent(b) }
        aside = j(home, ".aside/u/0")
        codex = j(codexHome ?? j(home, ".codex"), "sessions")
        claude = j(claudeHome ?? j(home, ".claude"), "projects")
        grok = j(grokHome ?? j(home, ".grok"), "sessions")
        agy = j(home, ".gemini/antigravity-cli")
    }
    static var current: ActivityRoots {
        ActivityRoots(home: Usage.home, codexHome: Usage.envDir("CODEX_HOME", ".codex"),
                      claudeHome: Usage.envDir("CLAUDE_CONFIG_DIR", ".claude"), grokHome: Usage.envDir("GROK_HOME", ".grok"))
    }
    var all: [String] { [aside, codex, claude, grok, agy] }
    // FSEvents takes at most 8 exclusion paths; these Aside folders hold nothing the classifier counts
    static let asideExcluded = ["memory", "projects", "skills", "cache", "context-awareness", "agents"]
    var excluded: [String] { ActivityRoots.asideExcluded.map { (aside as NSString).appendingPathComponent($0) } }
}

enum ActivityClassifier {
    static func under(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }

    static func classify(_ path: String, _ r: ActivityRoots) -> ActivitySource? {
        if under(path, r.aside) {
            let rest = String(path.dropFirst(r.aside.count))
            if rest == "/state.db" || rest == "/state.db-wal" { return .asideState }
            let parts = rest.split(separator: "/")
            if parts.count == 3 && parts[0] == "sessions" && parts[2] == "messages.jsonl" { return .asideSession(path) }
            return nil
        }
        if under(path, r.codex) { return .codex }
        if under(path, r.claude) { return .claude }
        if under(path, r.grok) { return .grok }
        if under(path, r.agy) {
            // agy's own bookkeeping (logs, update checks, caches, the summaries db) is written by every run,
            // including our /usage: only conversations and brain files mean someone used agy
            let rest = String(path.dropFirst(r.agy.count))
            for p in ["/conversations/", "/brain/"] where rest.hasPrefix(p) { return .agy }
            return nil
        }
        return nil
    }

    // Aside's provider id -> the service whose quota it uses; nil = unknown (then all quick services)
    static func provider(aside id: String) -> Provider? {
        let l = id.lowercased()
        if l.contains("claude") || l.contains("anthropic") { return .claude }
        if l.contains("codex") || l.contains("openai") || l.contains("chatgpt") { return .codex }
        if l.contains("grok") || l.contains("xai") { return .grok }
        if l.contains("gemini") || l.contains("antigravity") || l.contains("google") { return .agy }
        return nil
    }
    // the last "provider":"..." in a chunk of messages.jsonl
    static func lastProviderId(_ text: String) -> String? {
        guard let r = text.range(of: "\"provider\":\"", options: .backwards) else { return nil }
        let tail = text[r.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        let id = String(tail[..<end])
        return id.isEmpty || id.count > 64 ? nil : id
    }
}

final class ActivityWatcher {
    // providers, broad (names no service), from an Aside chat file, label for the log; called on the main queue
    var onActivity: (Set<Provider>, Bool, Bool, String) -> Void = { _, _, _, _ in }
    private let queue = DispatchQueue(label: "UsageGauge.activity")
    private var stream: FSEventStreamRef?
    private(set) var roots: [String] = []
    private let lock = NSLock()
    private var ignoreAgyUntil = Date.distantPast
    private var providerCache: [String: (id: String?, at: Date)] = [:]   // queue only

    // our own `agy -p /usage` writes into agy's folder too: ignore that folder while it runs and shortly after
    func ignoreAgy(until d: Date) { lock.lock(); ignoreAgyUntil = d; lock.unlock() }

    func refreshRoots() {
        let r = ActivityRoots.current
        var isDir: ObjCBool = false
        let have = r.all.filter { FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue }
        if have == roots && stream != nil { return }
        stop()
        roots = have
        guard !have.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, n, paths, _, _ in
            guard let info = info else { return }
            let me = Unmanaged<ActivityWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self)
            var list: [String] = []
            for i in 0..<min(n, arr.count) { if let s = arr[i] as? String { list.append(s) } }
            me.handle(list)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, cb, &ctx, have as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, flags) else {
            Log.write("activity: could not watch files"); return
        }
        let skip = r.excluded.filter { FileManager.default.fileExists(atPath: $0) }
        if !skip.isEmpty && have.contains(r.aside) { _ = FSEventStreamSetExclusionPaths(s, skip as CFArray) }
        FSEventStreamSetDispatchQueue(s, queue)
        if FSEventStreamStart(s) { stream = s; Log.write("activity: watching " + have.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")) }
        else { FSEventStreamInvalidate(s); FSEventStreamRelease(s); Log.write("activity: could not start the file watch") }
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil
    }

    // on `queue`
    private func handle(_ paths: [String]) {
        let r = ActivityRoots.current
        lock.lock(); let agyMuted = Date() < ignoreAgyUntil; lock.unlock()
        var ps = Set<Provider>(), broad = false, aside = false, labels: [String] = []
        func label(_ s: String) { if !labels.contains(s) { labels.append(s) } }
        for p in paths {
            guard let src = ActivityClassifier.classify(p, r) else { continue }
            switch src {
            case .asideState: broad = true; label("Aside")
            case .asideSession(let file):
                // a chat on a known service: that service. Not known yet (a new chat before its first reply, or
                // Aside's own provider): treated like state.db, all quick services at the longer broad gap
                let id = asideProvider(file)
                if let id = id, let prov = ActivityClassifier.provider(aside: id) { aside = true; ps.insert(prov); label("Aside " + id) }
                else { broad = true; label("Aside") }
            case .codex: ps.insert(.codex); label("Codex")
            case .claude: ps.insert(.claude); label("Claude Code")
            case .grok: ps.insert(.grok); label("Grok")
            case .agy: if !agyMuted { ps.insert(.agy); label("agy") }
            }
        }
        if ps.isEmpty && !broad { return }
        let l = labels.joined(separator: ", ")
        DispatchQueue.main.async { self.onActivity(ps, broad, aside, l) }
    }

    // read the last 64 KB of the chat log once a minute per chat (a chat rarely switches service)
    private func asideProvider(_ file: String) -> String? {
        if let c = providerCache[file], Date().timeIntervalSince(c.at) < 60 { return c.id }
        var id: String?
        if let h = FileHandle(forReadingAtPath: file) {
            let size = h.seekToEndOfFile()
            h.seek(toFileOffset: size > 65536 ? size - 65536 : 0)
            let d = h.readDataToEndOfFile(); try? h.close()
            id = ActivityClassifier.lastProviderId(String(decoding: d, as: UTF8.self))
        }
        if providerCache.count > 64 { providerCache.removeAll() }
        if id != nil { providerCache[file] = (id, Date()) }   // a new chat gets its provider with the first reply
        return id
    }
}

// Network came back or changed (Wi-Fi <-> Ethernet, VPN): one callback on the main queue, never for the first state.
final class NetworkWatch {
    private let monitor = NWPathMonitor()
    private var last: String?
    var onChange: () -> Void = {}
    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let sig = (path.status == .satisfied ? "up" : "down") + "|" + path.availableInterfaces.map(\.name).joined(separator: ",")
            let prev = self.last; self.last = sig
            if prev != nil && prev != sig && path.status == .satisfied { DispatchQueue.main.async { self.onChange() } }
        }
        monitor.start(queue: DispatchQueue(label: "UsageGauge.network"))
    }
}
