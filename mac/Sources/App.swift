import AppKit
import SwiftUI
import Foundation

// UsageGauge for macOS: a menu bar item showing the lowest weekly limit left across Codex, Claude, Grok
// and Antigravity. Click for per-service details, the local usage dashboard, refresh and quit.

enum Service: Int, CaseIterable { case codex, claude, grok }
let serviceNames = ["Codex", "Claude", "Grok"]

// Merge / SameLogin carried over from UsageGauge.cs: a value is only carried over when the failing lookup
// provably used the same login, never across an account switch.
enum Merge {
    static let staleMainMin = 12.0, staleAgMin = 35.0

    static func sameLogin(_ prev: Quota, _ fresh: Quota, _ hasLogin: Bool) -> Bool {
        if !hasLogin { return true }                                    // Antigravity: no identity is exposed
        if let a = prev.accountKey, let b = fresh.accountKey { return a == b }
        if let a = prev.credKey, let b = fresh.credKey { return a == b }
        return false                                                    // login unreadable or unidentified: don't guess
    }
    static func merge(_ prev: Quota, _ fresh: Quota, staleAfterMin: Double, hasLogin: Bool) -> Quota {
        if fresh.ok {
            fresh.lastOk = Date()
            if prev.ok && hasLogin {
                let knownBoth = prev.accountKey != nil && fresh.accountKey != nil
                if knownBoth && prev.accountKey != fresh.accountKey {
                    fresh.accountChanged = Date()
                    Log.write(fresh.name + " account changed: now showing the signed-in account")
                } else if knownBoth { fresh.accountChanged = prev.accountChanged }
                // same token, profile lookup failed this time: the account is provably unchanged
                if fresh.accountKey == nil, let c = prev.credKey, c == fresh.credKey {
                    fresh.accountKey = prev.accountKey; fresh.account = prev.account; fresh.accountChanged = prev.accountChanged
                }
            }
            return fresh
        }
        if prev.ok && sameLogin(prev, fresh, hasLogin) {
            prev.failing = true; prev.error = fresh.error
            // network blips heal by themselves; auth/format errors won't, so show those right away
            let age = prev.lastOk.map { Date().timeIntervalSince($0) / 60 } ?? .infinity
            prev.stale = !fresh.transient || age >= staleAfterMin
            Log.write(prev.name + " fetch failed: " + (fresh.error ?? ""))
            return prev
        }
        if prev.ok { Log.write(fresh.name + " failed for the current login (previous value from another or unknown login dropped): " + (fresh.error ?? "")) }
        else if let e = fresh.error, !fresh.noLogin, !fresh.notInstalled { Log.write(fresh.name + " failed: " + e) }
        if fresh.account == nil, let k = fresh.accountKey, k == prev.accountKey { fresh.account = prev.account }
        return fresh
    }
    // the value is old even without a failure (e.g. the Mac slept)
    static func showStale(_ q: Quota, ag: Bool) -> Bool {
        guard q.ok else { return false }
        if q.stale { return true }
        guard let t = q.lastOk else { return false }
        return Date().timeIntervalSince(t) / 60 >= (ag ? staleAgMin : staleMainMin)
    }
}

enum Fetch {
    // all three at once, for `--probe` and `--render-preview` only; the app fetches each service on its own (Refresh.swift)
    static func main() -> [Quota] {
        let jobs: [() -> Quota] = [Usage.codex, Usage.claude, Usage.grok]
        var out = [Quota?](repeating: nil, count: 3)
        let lock = NSLock(), group = DispatchGroup()
        for (i, job) in jobs.enumerated() {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let q = job(); q.name = serviceNames[i]
                lock.lock(); out[i] = q; lock.unlock(); group.leave()
            }
        }
        _ = group.wait(timeout: .now() + Usage.timeout * 2 + 4)
        lock.lock(); defer { lock.unlock() }
        return (0..<3).map { i in
            if let q = out[i] { return q }
            let q = Quota.fail("시간 초과", transient: true); q.name = serviceNames[i]; return q
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var qs: [Quota] = serviceNames.map { n in let q = Quota(); q.name = n; return q }
    var ag: [Quota] = []
    var loaded = false
    var timer: Timer?
    var st: [Provider: ProviderState] = Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, ProviderState()) })
    var debouncer = Debouncer.others()        // Codex, Grok, Antigravity: 10 s quiet, 30 s at most
    var claudeDebouncer = Debouncer.claude()  // Claude: once the chat has been quiet 20 s (3 min at most)
    let watcher = ActivityWatcher()
    let network = NetworkWatch()
    var lastRootsCheck = Date()
    var shownFreshness: String?
    var busy: Bool { st.values.contains { $0.inFlight } }
    var habitRunning = false
    var habitLastRun: Date? = UserDefaults.standard.object(forKey: HabitGate.defaultsKey) as? Date
    let popover = NSPopover()
    let model = PopoverModel()
    var quitMenu: NSMenu!

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("UsageGauge \(AppVersion.string) started")
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            b.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
            b.imagePosition = .imageLeft
            b.imageScaling = .scaleNone   // the strip is drawn on whole pixels; never resample it
            b.target = self; b.action = #selector(statusClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        // right click: a quiet menu with "종료" only
        quitMenu = NSMenu()
        let quit = NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q"); quit.target = self
        quitMenu.addItem(quit)

        model.onDetails = { [weak self] in self?.popover.performClose(nil); self?.openDashboard() }
        model.onHabit = { [weak self] in self?.runHabit(openWhenDone: true) }
        model.onRefresh = { [weak self] in self?.refresh(force: true) }
        let host = NSHostingController(rootView: PopoverView(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
        // the approved design has no arrow; hide it only where AppKit offers the switch
        if popover.responds(to: NSSelectorFromString("setShouldHideAnchor:")) { popover.setValue(true, forKey: "shouldHideAnchor") }

        // Antigravity never starts sooner than 10 min after its last run, whatever asks (each run is a big CLI)
        st[.agy]!.floorGap = RefreshPolicy.minGap(.agy)
        updateStatusItem(); updateModel()
        pump()                                    // first lookup of every service, each on its own
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.pump() }
        timer?.tolerance = 1
        // AI use seen in the tools' files -> look again after a short debounce
        watcher.onActivity = { [weak self] ps, broad, aside, label in
            guard let self = self else { return }
            let now = Date()
            self.debouncer.note(ps, broad: broad, asideSession: aside, label: label, at: now)
            self.claudeDebouncer.note(ps, broad: broad, asideSession: aside, label: label, at: now)
        }
        watcher.refreshRoots()
        network.onChange = { [weak self] in self?.wokeOrOnline("네트워크 변경") }
        network.start()
        let nc = NSWorkspace.shared.notificationCenter
        for (name, why) in [(NSWorkspace.didWakeNotification, "깨어남"), (NSWorkspace.sessionDidBecomeActiveNotification, "로그인 화면 복귀"),
                            (NSWorkspace.screensDidWakeNotification, "화면 켜짐")] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + RefreshPolicy.wakeDelay) { self?.wokeOrOnline(why) }
            }
        }
    }

    @objc func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            item.menu = quitMenu; item.button?.performClick(nil); item.menu = nil   // shows the menu at the item
            return
        }
        if popover.isShown { popover.performClose(nil); return }
        // opening the popover asks for fresh values too (still within each service's minimum gap)
        for p in RefreshPolicy.followsGeneralTriggers { Sched.request(&st[p]!, gap: RefreshPolicy.minGap(p), reason: "열기") }
        pump()
        updateModel()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // every 5 s: act on debounced activity, start whatever is due, keep "N분 전 확인" current
    func pump() {
        let now = Date()
        for act in [debouncer.takeIfDue(now: now), claudeDebouncer.takeIfDue(now: now)].compactMap({ $0 }) {
            for p in act.specific { Sched.request(&st[p]!, gap: RefreshPolicy.minGap(p), reason: "활동: " + act.label) }
            for p in act.broad { Sched.request(&st[p]!, gap: RefreshPolicy.broadMinGap, reason: "활동: " + act.label) }
        }
        for p in Provider.allCases where Sched.decide(st[p]!, now: now, idle: RefreshPolicy.idle(p)) == .start {
            start(p, now: now)
        }
        if now.timeIntervalSince(lastRootsCheck) >= 300 { lastRootsCheck = now; watcher.refreshRoots() }   // new tool folders
        let f = freshness()
        if f != shownFreshness { shownFreshness = f; updateStatusItem(); if popover.isShown { updateModel() } }
        else if popover.isShown && model.habitWait != habitWaitText(now) { updateModel() }
    }

    func start(_ p: Provider, now: Date) {
        let s = st[p]!
        let why = s.reason ?? (s.blockedUntil != nil ? "재시도(\(s.failures)회 실패 뒤)" : s.lastStart == nil ? "시작" : "주기")
        Sched.started(&st[p]!, now: now)
        if p == .agy { watcher.ignoreAgy(until: .distantFuture) }
        model.busy = true
        DispatchQueue.global(qos: .utility).async {
            let r = Fetch.one(p)
            DispatchQueue.main.async { self.finish(p, r, why: why, started: now) }
        }
    }

    func finish(_ p: Provider, _ r: FetchResult, why: String, started: Date) {
        let now = Date()
        let gapBefore = st[p]!.floorGap
        Sched.finished(&st[p]!, now: now, transient: r.transient, rateLimited: r.rateLimited, retryAfter: r.retryAfter, adaptive: p == .claude)
        if p == .agy {
            watcher.ignoreAgy(until: now.addingTimeInterval(10))
            let a = r.quotas
            if a.count == ag.count && a.count == 2 {
                ag = (0..<2).map { Merge.merge(ag[$0], a[$0], staleAfterMin: Merge.staleAgMin, hasLogin: false) }
            } else {
                for q in a where q.ok { q.lastOk = now }
                ag = a
            }
        } else if let q = r.quotas.first {
            if p == .claude && q.loginGeneration != Usage.claudeGeneration() {
                // the account changed after this lookup began: its answer may be the old account's, so ask again
                Log.write("refresh Claude [\(why)] dropped: it began before the account changed")
                Sched.request(&st[p]!, gap: RefreshPolicy.minGap(p), reason: "계정 바뀜")
            } else {
                qs[p.rawValue] = Merge.merge(qs[p.rawValue], q, staleAfterMin: Merge.staleMainMin, hasLogin: true)
            }
        }
        loaded = true
        let secs = String(format: "%.1f", now.timeIntervalSince(started))
        let res = r.quotas.map { $0.ok ? "\(Usage.remainingNumber($0.remaining))%" : ($0.error ?? "실패") }.joined(separator: "/")
        var line = "refresh \(p.name) [\(why)] \(res) \(secs)s"
        if let b = st[p]!.blockedUntil { line += ", next try in \(Int(b.timeIntervalSince(now)))s" }
        if p == .claude && st[p]!.floorGap != gapBefore { line += ", min gap \(Int(st[p]!.floorGap))s" }
        Log.write(line)
        DashboardFeed.write(qs)
        shownFreshness = freshness()
        updateStatusItem(); updateModel()
    }

    // the refresh button: every service now (10 s floor), even out of a network backoff; a 429 block is kept.
    // Claude's kept login is dropped, so the next lookup reads the login again (a switched account shows at once), and
    // the signed-in account is checked now, so a lookup already running for the old account is not shown.
    func refresh(force: Bool) {
        Usage.keychainDenied = false
        Usage.forgetClaudeLogin()
        DispatchQueue.global(qos: .utility).async { Usage.noteClaudeAccount(Usage.claudeConfigAccount()) }
        let now = Date()
        for p in Provider.allCases {
            Sched.clearNetworkBackoff(&st[p]!, now: now)
            Sched.request(&st[p]!, gap: RefreshPolicy.forceMinGap, reason: "새로고침")
        }
        pump()
    }

    // wake, unlock, network back: a failed lookup is retried (within its minimum gap); Antigravity is left alone
    func wokeOrOnline(_ why: String) {
        Sched.generalTrigger(&st, now: Date(), reason: why)
        watcher.refreshRoots()
        pump()
    }

    // when the values shown for Codex/Claude/Grok were last confirmed (the oldest of them)
    var lastConfirmed: Date? {
        let oks = qs.filter { $0.ok }.compactMap { $0.lastOk }
        if let m = oks.min() { return m }
        return [Provider.codex, .claude, .grok].compactMap { st[$0]?.lastEnd }.max()
    }
    func freshness() -> String? { freshnessText(lastConfirmed) }

    var rings: [Quota] { Design.ringQuotas(main: qs, ag: ag) }

    // menu bar (variant C): every service with a value as logo + small remaining bar + number (or refill day),
    // in the fixed order Codex, Claude, Grok, Gemini 4 Argon, Antigravity; see MenuBarStrip.
    // Before the first lookup, or when nothing was read: the grey empty ring as before.
    func updateStatusItem() {
        guard let b = item.button else { return }
        let r = rings
        let strip = loaded ? MenuBarStrip.entries(main: qs, ag: ag) : []
        if !strip.isEmpty {
            b.image = MenuBarStrip.image(strip)
            b.title = ""
            b.toolTip = MenuBarStrip.tooltip(strip) + (freshness().map { "\n" + $0 } ?? "")
            return
        }
        let i = loaded ? Design.lowest(r) : nil
        let rem = i.map { r[$0].remaining }, logo = i.map { Design.logoKeys[$0] }
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            Design.menuBarRing(remaining: rem, logoKey: logo, dark: dark).draw(in: rect)
            return true
        }
        b.image = img
        b.title = rem.map { Usage.remainingNumber($0) + "%" } ?? ""
        b.toolTip = i.map { "가장 급한 한도: \(r[$0].name) \(Usage.remainingNumber(r[$0].remaining))% 남음" }
            ?? (loaded ? "UsageGauge: 읽은 한도가 없어요" : "UsageGauge: 불러오는 중")
    }

    func updateModel() {
        let r = rings
        model.gauges = loaded ? zip(r, Design.logoKeys).map { Design.gauge($0, logo: $1) }
            : Design.logoKeys.map { k in let q = Quota(); q.error = "확인 전"; return Design.gauge(q, logo: k) }
        model.header = Design.header(lastCheck: lastConfirmed, main: qs)
        model.todo = Design.loadTodo()
        model.busy = busy
        model.habitRunning = habitRunning
        model.habitWait = habitWaitText(Date())
    }
    func habitWaitText(_ now: Date) -> String? { HabitGate.waitMinutes(lastRun: habitLastRun, now: now).map(HabitGate.waitText) }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func openDashboard() {
        if FileManager.default.fileExists(atPath: Paths.page) {
            NSWorkspace.shared.open(URL(fileURLWithPath: Paths.page)); return
        }
        alert("사용량 상세 화면이 아직 없어요.",
              "저장소의 mac/install-dashboard.sh 를 한 번 실행하면 화면이 만들어지고, 자동 갱신을 켜면 30분마다 새로 만들어져요.")
    }

    func alert(_ title: String, _ text: String) {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.alertStyle = .informational
        a.addButton(withTitle: "확인"); a.runModal()
    }

    // ---- usagegauge://habit-check (the dashboard's "AI로 진단하기" link; that page reloads itself) ----
    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else { return }
        guard s.range(of: "^usagegauge://habit-check/?$", options: [.regularExpression, .caseInsensitive]) != nil else {
            Log.write("ignored url scheme request"); return
        }
        runHabit(openWhenDone: false, fromURL: true)
    }
    // the popover's "AI 진단": same run; nothing is open yet, so the rebuilt page is shown when it is done
    // A link can be opened by any page or app, and each run uses some of the quota: a link asks first. Either way
    // runs are at least 10 minutes apart.
    func runHabit(openWhenDone: Bool, fromURL: Bool = false) {
        switch HabitGate.decide(fromURL: fromURL, running: habitRunning, lastRun: habitLastRun, now: Date()) {
        case .busy: return
        case .wait(let m):
            Log.write("habit check: asked again within 10 min (\(fromURL ? "link" : "button")), not run")
            alert("AI 진단은 방금 돌렸어요.", HabitGate.waitText(m) + ".")
            return
        case .confirm:
            popover.performClose(nil)
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert(); a.messageText = HabitGate.confirmTitle; a.informativeText = HabitGate.confirmText
            a.addButton(withTitle: "진단하기"); a.addButton(withTitle: "취소")
            if a.runModal() != .alertFirstButtonReturn { Log.write("habit check: link request cancelled"); return }
            if habitRunning { return }
        case .run: break
        }
        guard FileManager.default.fileExists(atPath: Paths.refreshScript), let node = nodePath() else {
            alert("AI 진단을 실행할 수 없어요.", "mac/install-dashboard.sh 로 사용량 상세 화면을 먼저 준비해 주세요. (Node.js 22.13 이상 필요)")
            return
        }
        habitRunning = true; model.habitRunning = true
        habitLastRun = Date(); UserDefaults.standard.set(habitLastRun, forKey: HabitGate.defaultsKey)
        model.habitWait = habitWaitText(Date())
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = ["--no-warnings", Paths.refreshScript, "--habit", "usagegauge://habit-check"]
        p.currentDirectoryURL = URL(fileURLWithPath: Paths.data)
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.habitRunning = false; self.model.habitRunning = false
                Log.write("habit check finished (exit \(proc.terminationStatus))")
                self.updateModel()
                if openWhenDone && proc.terminationStatus == 0 { self.openDashboard() }
            }
        }
        do { try p.run() } catch {
            habitRunning = false; model.habitRunning = false; Log.write("habit check: could not start node")
            habitLastRun = nil; UserDefaults.standard.removeObject(forKey: HabitGate.defaultsKey); model.habitWait = nil
        }
    }
    func nodePath() -> String? {
        if let s = try? String(contentsOfFile: Paths.nodePathFile, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if FileManager.default.isExecutableFile(atPath: t) { return t }
        }
        for p in ["/opt/homebrew/bin/node", "/usr/local/bin/node"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }
}

// `UsageGauge --probe`: one lookup printed as JSON lines (masked account, no tokens). For checks from a terminal.
func runProbe() {
    let main = Fetch.main(), ag = Antigravity.fetch()
    let iso = DashboardFeed.iso
    for q in main + ag {
        var o: [String: Any] = ["service": q.name, "ok": q.ok]
        if q.ok { o["remaining"] = (q.remaining * 100).rounded() / 100; o["resetsAt"] = q.resetsAt.map(iso) ?? NSNull(); o["account"] = DashboardFeed.mask(q.account) ?? NSNull() }
        else { o["error"] = q.error ?? NSNull(); o["noLogin"] = q.noLogin; o["notInstalled"] = q.notInstalled }
        if let e = q.extra { o["extra"] = e }
        print(DashboardFeed.json(o))
    }
}

// `UsageGauge --render-preview <folder>`: the popover as PNGs (mock values dark/light + this Mac's real state).
@MainActor
func renderPreview(_ dir: String) {
    _ = NSApplication.shared
    let main = Fetch.main()
    for q in main where q.ok { q.lastOk = Date() }
    let ag = Antigravity.fetch()
    let rings = Design.ringQuotas(main: main, ag: ag)
    let m = PopoverModel()
    m.gauges = zip(rings, Design.logoKeys).map { Design.gauge($0, logo: $1) }
    m.header = Design.header(lastCheck: Date(), main: main)
    m.todo = Design.loadTodo()
    let low = Design.lowest(rings)
    for p in Preview.render(to: dir, real: (m, low.map { rings[$0].remaining }, low.map { Design.logoKeys[$0] })) { print(p) }
}

// The AI habit check: a link (usagegauge://habit-check) asks first, the in-app button runs at once; both at most
// once every 10 minutes. Pure, unit tested.
enum HabitGate {
    static let minGap: TimeInterval = 10 * 60
    static let defaultsKey = "habitCheckLastRun"
    static let confirmTitle = "AI 진단을 돌릴까요?", confirmText = "한도를 조금 써요."
    enum Step: Equatable { case run, confirm, wait(Int), busy }
    static func waitMinutes(lastRun: Date?, now: Date) -> Int? {
        guard let l = lastRun else { return nil }
        let left = l.addingTimeInterval(minGap).timeIntervalSince(now)
        return left > 0 ? max(1, Int(ceil(left / 60))) : nil
    }
    static func waitText(_ minutes: Int) -> String { "\(minutes)분 뒤에 다시 돌릴 수 있어요" }
    static func decide(fromURL: Bool, running: Bool, lastRun: Date?, now: Date) -> Step {
        if running { return .busy }
        if let m = waitMinutes(lastRun: lastRun, now: now) { return .wait(m) }
        return fromURL ? .confirm : .run
    }
}

// shown in the log at launch, so a rebuilt and reinstalled app can be told apart from the previous one
enum AppVersion { static let string = "1.0.4" }

@main
struct UsageGaugeMain {
    static func main() {
        if CommandLine.arguments.contains("--probe") { runProbe(); return }
        if let i = CommandLine.arguments.firstIndex(of: "--render-preview"), i + 1 < CommandLine.arguments.count {
            renderPreview(CommandLine.arguments[i + 1]); return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
