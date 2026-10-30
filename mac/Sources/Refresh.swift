import Foundation

// When each service is looked up again (2026-10-30, "바로바로 보이게"; load fixes 2026-10-31, "잡아바바").
// Every service is fetched on its own, so one slow lookup (a keychain prompt, a CLI run) never holds up the others.
// A lookup starts when:
//  - its idle interval has passed (3 min; Antigravity 20 min), or
//  - AI activity was seen (files written by Aside, Codex, Claude Code, Grok, agy), after a debounce. Claude waits
//    until its chat files have been quiet for 20 s (at most 3 min), so one Aside reply asks once, at its end.
//    Antigravity only reacts to agy's own conversation files, at most every 10 min,
//  - the popover is opened, the Mac wakes / the session becomes active, or the network comes back (not Antigravity:
//    every agy run starts a CLI of about 300 MB for ~9 s),
// and never sooner than the service's minimum gap since its last start (the endpoints are rate limited), also when a
// backoff ends: a retry waits for whichever is later, the end of the backoff or the last start plus the minimum gap.
// Claude's gap adapts: each 429 doubles it (90 s -> at most 10 min, a longer Retry-After wins), and three successes
// in a row halve it again, down to 90 s.
// Transient failures (network, 5xx, CLI timeout) back off exponentially; a Retry-After is respected.
// Everything here is pure (no clock, no I/O), so it is unit tested in Tests/LogicTests.swift.

enum Provider: Int, CaseIterable, Hashable {
    case codex, claude, grok, agy
    var name: String { ["Codex", "Claude", "Grok", "Antigravity"][rawValue] }
    static let quick: Set<Provider> = [.codex, .claude, .grok]
}

enum RefreshPolicy {
    static let debounce: TimeInterval = 10          // quiet time after the last activity before looking
    static let maxWait: TimeInterval = 30           // ...but no longer than this while activity keeps going
    static let claudeQuiet: TimeInterval = 20       // Claude: the chat must be quiet this long (the reply is done)
    static let claudeMaxWait: TimeInterval = 180    // ...or this long since the first write of a long run
    static let broadMinGap: TimeInterval = 120      // activity that names no service (Aside's state.db alone)
    static let forceMinGap: TimeInterval = 10       // the refresh button
    static let wakeDelay: TimeInterval = 5          // the network needs a moment after wake
    static let backoffBase: TimeInterval = 60, backoffCap: TimeInterval = 30 * 60, retryAfterCap: TimeInterval = 3600
    // Claude's usage endpoint: the adaptive minimum gap between two lookups
    static let claudeMinGap: TimeInterval = 90, claudeGapCap: TimeInterval = 10 * 60, claudeDecayAfter = 3

    static func idle(_ p: Provider) -> TimeInterval { p == .agy ? 20 * 60 : 3 * 60 }
    static func minGap(_ p: Provider) -> TimeInterval {
        switch p {
        case .codex, .grok: return 45
        case .claude: return claudeMinGap   // the usage endpoint answers 429 when asked too often
        case .agy: return 10 * 60           // spawns the agy CLI (~9 s, ~300 MB)
        }
    }
    // services that a popover open, wake or network change asks for (agy only for its own activity or the button)
    static let followsGeneralTriggers: Set<Provider> = [.codex, .claude, .grok]
    // n-th transient failure in a row: 1, 2, 4, 8, 16 ... minutes, at most 30; 429 waits at least 2 minutes;
    // a Retry-After (capped at an hour) wins when longer.
    static func backoff(failures: Int, rateLimited: Bool, retryAfter: TimeInterval?) -> TimeInterval {
        let n = max(1, failures)
        var d = min(backoffCap, backoffBase * pow(2, Double(min(n - 1, 10))))
        if rateLimited { d = max(d, 120) }
        if let r = retryAfter, r > 0 { d = max(d, min(r, retryAfterCap)) }
        return d
    }
    // Claude after a 429: the gap doubles (at most 10 min); the block is that gap, or a longer Retry-After
    static func claudeGapAfter429(_ gap: TimeInterval) -> TimeInterval { min(claudeGapCap, max(claudeMinGap, gap) * 2) }
    static func claudeBlock(gap: TimeInterval, retryAfter: TimeInterval?) -> TimeInterval {
        max(gap, min(retryAfter ?? 0, retryAfterCap))
    }
}

struct ProviderState: Equatable {
    var lastStart: Date?
    var lastEnd: Date?
    var inFlight = false
    var failures = 0                 // transient failures in a row
    var blockedUntil: Date?          // backoff: no lookup before this, then one retry
    var rateLimited = false          // the block came from a 429
    var requestGap: TimeInterval?    // a pending activity/open/wake request and the minimum gap it must respect
    var reason: String?              // what asked for the pending request (log only)
    var floorGap: TimeInterval = 0   // no start sooner than this after the last one, whatever asked (Claude: adaptive)
    var okStreak = 0                 // successes in a row since the gap last changed (Claude's decay)
}

enum Decision: Equatable { case start, wait(Date), busy }

enum Sched {
    static func decide(_ s: ProviderState, now: Date, idle: TimeInterval) -> Decision {
        if s.inFlight { return .busy }
        if let b = s.blockedUntil {                                          // backing off: activity can't hurry it
            // the minimum gap since the last start holds on this path too (agy: 10 min after a 30 s timeout)
            let at = s.lastStart.map { max(b, $0.addingTimeInterval(s.floorGap)) } ?? b
            return at > now ? .wait(at) : .start
        }
        guard let last = s.lastStart else { return .start }
        if let g = s.requestGap { let at = last.addingTimeInterval(max(g, s.floorGap)); return at <= now ? .start : .wait(at) }
        let at = last.addingTimeInterval(max(idle, s.floorGap))
        return at <= now ? .start : .wait(at)
    }
    // a request keeps the smallest gap asked for
    static func request(_ s: inout ProviderState, gap: TimeInterval, reason: String) {
        if let g = s.requestGap, g <= gap { return }
        s.requestGap = gap; s.reason = reason
    }
    static func started(_ s: inout ProviderState, now: Date) {
        s.lastStart = now; s.inFlight = true; s.requestGap = nil; s.reason = nil
    }
    static func finished(_ s: inout ProviderState, now: Date, transient: Bool, rateLimited: Bool, retryAfter: TimeInterval?, adaptive: Bool = false) {
        s.inFlight = false; s.lastEnd = now
        if adaptive {
            // Claude: the minimum gap follows the endpoint's rate limit
            let gap = max(RefreshPolicy.claudeMinGap, s.floorGap)
            if rateLimited {
                s.floorGap = RefreshPolicy.claudeGapAfter429(gap); s.okStreak = 0
                s.failures += 1; s.rateLimited = true
                s.blockedUntil = now.addingTimeInterval(RefreshPolicy.claudeBlock(gap: s.floorGap, retryAfter: retryAfter))
                return
            }
            s.floorGap = gap
            if !transient {
                s.okStreak += 1
                if s.okStreak >= RefreshPolicy.claudeDecayAfter && gap > RefreshPolicy.claudeMinGap {
                    s.floorGap = max(RefreshPolicy.claudeMinGap, gap / 2); s.okStreak = 0
                }
            } else { s.okStreak = 0 }
        }
        if transient {
            s.failures += 1; s.rateLimited = rateLimited
            s.blockedUntil = now.addingTimeInterval(RefreshPolicy.backoff(failures: s.failures, rateLimited: rateLimited, retryAfter: retryAfter))
        } else {
            s.failures = 0; s.blockedUntil = nil; s.rateLimited = false
        }
    }
    // wake / network back / refresh button: a network backoff is pointless now; a 429 block stays
    static func clearNetworkBackoff(_ s: inout ProviderState, now: Date) {
        if s.blockedUntil != nil && !s.rateLimited { s.blockedUntil = now }
    }
    // a general trigger (wake, unlock, network back): only the services that follow general triggers lose a network
    // backoff and get a request; Antigravity keeps its backoff (each run is a big CLI)
    static func generalTrigger(_ st: inout [Provider: ProviderState], now: Date, reason: String) {
        for p in RefreshPolicy.followsGeneralTriggers {
            clearNetworkBackoff(&st[p]!, now: now)
            request(&st[p]!, gap: RefreshPolicy.minGap(p), reason: reason)
        }
    }
}

// Collects activity and says when to act on it: `quiet` after the last event, but at most `maxWait` after the
// first one, so a long agent run that writes every second still refreshes now and then (within min gaps).
// Each debouncer covers some services: the app keeps one for Claude (20 s quiet, 3 min at most, so an Aside
// reply asks once when it is done) and one for the rest (10 s, 30 s).
struct Debouncer: Equatable {
    var first: Date?, last: Date?
    var specific: Set<Provider> = []
    var broad = false            // something happened that names no service
    var sawAsideSession = false  // an Aside chat file changed: then state.db changes are just that chat
    var labels: [String] = []
    var covers: Set<Provider> = Set(Provider.allCases)
    var quiet: TimeInterval = RefreshPolicy.debounce
    var maxWait: TimeInterval = RefreshPolicy.maxWait

    init(covers: Set<Provider> = Set(Provider.allCases), quiet: TimeInterval = RefreshPolicy.debounce, maxWait: TimeInterval = RefreshPolicy.maxWait) {
        self.covers = covers; self.quiet = quiet; self.maxWait = maxWait
    }
    static func claude() -> Debouncer { Debouncer(covers: [.claude], quiet: RefreshPolicy.claudeQuiet, maxWait: RefreshPolicy.claudeMaxWait) }
    static func others() -> Debouncer { Debouncer(covers: Set(Provider.allCases).subtracting([.claude])) }

    // activity that touches none of the covered services is ignored, so it can't push the quiet time back
    mutating func note(_ ps: Set<Provider>, broad b: Bool, asideSession: Bool, label: String, at now: Date) {
        let mine = ps.intersection(covers)
        // state.db written together with a chat file is just that chat, not activity of its own
        let broadMine = b && !asideSession && !covers.intersection(Provider.quick).isEmpty
        if mine.isEmpty && !broadMine { return }
        if first == nil { first = now }
        last = now
        specific.formUnion(mine); broad = broad || broadMine; sawAsideSession = sawAsideSession || asideSession
        for l in label.components(separatedBy: ", ") where !l.isEmpty && !labels.contains(l) && labels.count < 6 { labels.append(l) }
    }
    func due() -> Date? {
        guard let f = first, let l = last else { return nil }
        return min(l.addingTimeInterval(quiet), f.addingTimeInterval(maxWait))
    }
    // specific providers use their own min gap; broad ones the longer broadMinGap
    mutating func takeIfDue(now: Date) -> (specific: Set<Provider>, broad: Set<Provider>, label: String)? {
        guard let d = due(), d <= now else { return nil }
        let spec = specific
        let br: Set<Provider> = broad && !sawAsideSession ? Provider.quick.intersection(covers).subtracting(spec) : []
        let label = labels.joined(separator: ", ")
        self = Debouncer(covers: covers, quiet: quiet, maxWait: maxWait)
        return (spec, br, label)
    }
}

struct FetchResult {
    var quotas: [Quota]
    var retryAfter: TimeInterval?
    var transient: Bool { quotas.contains { !$0.ok && $0.transient } }
    var rateLimited: Bool { quotas.contains { !$0.ok && $0.rateLimited } }
}

extension Fetch {
    // one service, on the calling (background) thread; Retry-After is read from the thread that ran the request
    static func one(_ p: Provider) -> FetchResult {
        Usage.clearRetryAfter()
        let qs: [Quota]
        switch p {
        case .codex: let q = Usage.codex(); q.name = serviceNames[0]; qs = [q]
        case .claude: let q = Usage.claude(); q.name = serviceNames[1]; qs = [q]
        case .grok: let q = Usage.grok(); q.name = serviceNames[2]; qs = [q]
        case .agy: qs = Antigravity.fetch()
        }
        return FetchResult(quotas: qs, retryAfter: Usage.takeRetryAfter())
    }
}

// "방금 확인" / "3분 전 확인" (same wording as the popover header)
func freshnessText(_ t: Date?, now: Date = Date()) -> String? {
    guard let t = t else { return nil }
    let m = Int(max(0, now.timeIntervalSince(t)) / 60)
    return m < 1 ? "방금 확인" : m < 60 ? "\(m)분 전 확인" : "\(m / 60)시간 전 확인"
}
