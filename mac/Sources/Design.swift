import AppKit
import Foundation

// Approved menu bar design (2026-10-30): ring gauges with service logos.
// Pure logic here (colors, which service is most urgent, texts, "지금 할 일"); drawing in PopoverView.swift.

enum Palette {
    static let green = NSColor(srgbRed: 0x2f / 255.0, green: 0xbf / 255.0, blue: 0x8a / 255.0, alpha: 1)
    static let amber = NSColor(srgbRed: 0xe9 / 255.0, green: 0xa9 / 255.0, blue: 0x2e / 255.0, alpha: 1)
    static let red = NSColor(srgbRed: 0xe5 / 255.0, green: 0x48 / 255.0, blue: 0x4d / 255.0, alpha: 1)
    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    struct Scheme { let bg, fg, sub, track, line, accent: NSColor }
    static let dark = Scheme(bg: hex(0x2a2730), fg: hex(0xf4f2f6), sub: hex(0xa7a1ae), track: NSColor(white: 1, alpha: 0.12),
                             line: NSColor(white: 1, alpha: 0.08), accent: hex(0xd3a6c7))
    static let light = Scheme(bg: hex(0xf7f6f9), fg: hex(0x1d1a21), sub: hex(0x6b6672), track: NSColor(white: 0, alpha: 0.08),
                              line: NSColor(white: 0, alpha: 0.07), accent: hex(0x7b3f6e))
}

enum RingTone: Equatable { case green, amber, red, off, stale }   // stale: an old value, drawn grey

enum Design {
    // remaining 60% or more green, 30% or more amber, below that red (raw value, before rounding)
    static func tone(_ remaining: Double) -> RingTone { remaining >= 60 ? .green : remaining >= 30 ? .amber : .red }
    static func color(_ t: RingTone) -> NSColor {
        switch t { case .green: return Palette.green; case .amber: return Palette.amber; case .red: return Palette.red; case .off: return .clear
        case .stale: return NSColor(white: 0.55, alpha: 0.7) }
    }

    // the four rings: Codex, Claude, Grok, Gemini (Antigravity). Antigravity's other pool is not a ring.
    static func ringQuotas(main: [Quota], ag: [Quota]) -> [Quota] {
        var four = Array(main.prefix(3))
        if let g = ag.first { four.append(g) } else { let q = Quota(); q.name = Antigravity.geminiName; q.error = "확인 전"; four.append(q) }
        return four
    }
    static let logoKeys = ["codex", "claude", "grok", "gemini"]

    // most urgent = lowest remaining among services that actually returned a value (no login / failures excluded).
    // A used-up service (0%) is skipped while another one still has room, as in the approved mock
    // (Grok used up, the bar shows Codex 38%); when everything left is used up, that one is shown.
    static func lowest(_ qs: [Quota]) -> Int? {
        var best: Int?, usedUp: Int?
        for (i, q) in qs.enumerated() where q.ok {
            if q.remaining <= 0 { if usedUp == nil { usedUp = i }; continue }
            if best == nil || q.remaining < qs[best!].remaining { best = i }
        }
        return best ?? usedUp
    }

    struct Gauge: Equatable {
        enum State: Equatable { case value(Double), usedUp, off }
        var logo: String          // asset key
        var state: State
        var percentText: String   // "38", "—"
        var caption: String       // reset time, "…까지", or a short status
        var detail: String?       // full status for the tooltip
        var tone: RingTone
        var fraction: Double      // 0...1 of the ring drawn
        var second: String? = nil       // the other window under the weekly ring: "5시간 55%", "5시간 다 씀"
        var secondReset: String? = nil  // when that window is low: "01:19에 다시 차요"
        var secondUsedUp = false        // the 5-hour window blocks the service for now (drawn in red)
    }

    // below this a shorter window also shows when it fills again
    static let secondLowBelow = 30.0

    // the line(s) under a weekly ring for the service's other windows (Codex and Claude 5-hour); nil when there is none
    static func secondLines(_ q: Quota, now: Date = Date(), tz: TimeZone = .current) -> (text: String, reset: String?, usedUp: Bool, detail: String)? {
        let ws = MenuBarStrip.others(q)
        guard !ws.isEmpty else { return nil }
        let text = ws.map { $0.label + " " + (MenuBarStrip.isUsedUp($0) ? "다 씀" : Usage.remainingNumber($0.remaining) + "%") }.joined(separator: ", ")
        // the reset of the lowest window, when it is low
        let low = ws.filter { $0.remaining < secondLowBelow }.min { $0.remaining < $1.remaining }
        var reset: String?
        if let l = low, let r = l.reset { reset = r > now ? MenuBarStrip.clock(r, tz: tz) + "에 다시 차요" : "곧 다시 차요" }
        let detail = ws.map { w -> String in
            var d = w.label + " " + (MenuBarStrip.isUsedUp(w) ? "다 씀" : Usage.remainingNumber(w.remaining) + "% 남음")
            if w.remaining < secondLowBelow, let r = w.reset { d += r > now ? ", " + MenuBarStrip.clock(r, tz: tz) + "에 다시 차요" : ", 곧 다시 차요" }
            return d
        }.joined(separator: "\n")
        return (text, reset, ws.contains(where: MenuBarStrip.isUsedUp), detail)
    }

    static func gauge(_ q: Quota, logo: String, now: Date = Date(), tz: TimeZone = .current) -> Gauge {
        if !q.ok {
            return Gauge(logo: logo, state: .off, percentText: "—", caption: shortStatus(q), detail: q.error, tone: .off, fraction: 0)
        }
        let reset = q.resetsAt.map { when($0, now: now, tz: tz) } ?? ""
        if q.remaining <= 0 {
            return Gauge(logo: logo, state: .usedUp, percentText: "—", caption: reset.isEmpty ? "다 씀" : reset + "까지",
                         detail: q.failing ? q.error : nil, tone: .red, fraction: 0)
        }
        // the ring is the weekly limit; the 5-hour window goes on a small line under it
        var g = Gauge(logo: logo, state: .value(q.remaining), percentText: Usage.remainingNumber(q.remaining), caption: reset,
                      detail: q.failing ? q.error : nil, tone: tone(q.remaining), fraction: min(1, q.remaining / 100))
        if let s = secondLines(q, now: now, tz: tz) {
            g.second = s.text; g.secondReset = s.reset; g.secondUsedUp = s.usedUp
            let weekLine = "주간 " + Usage.remainingNumber(q.remaining) + "% 남음"
            g.detail = [weekLine, s.detail, g.detail].compactMap { $0 }.joined(separator: "\n")
        }
        return g
    }

    // ---- popover rows, B (owner's choice 2026-11-03, "주간 5시간 구분해서 볼 수 있게"): one row per service with a
    // weekly bar and a 5-hour bar under it, the same shape, so the two limits read apart at a glance. A service without
    // a 5-hour limit says "없음" on that line. A value that is old (failed refresh, or not read for a while) is drawn
    // grey with "N시간 전 값" beside the name.
    struct Line: Equatable {
        var label: String          // "주간", "5시간"
        var fraction: Double       // 0...1 of the bar filled
        var value: String          // "81%", "다 씀", "없음", "—"
        var reset: String          // "11/9 12:00", "03:20", a short status, or ""
        var tone: RingTone         // bar color; .off = no fill
        var emphasis: Bool         // value drawn red (used up)
        var muted: Bool            // value drawn grey ("없음", "—")
    }
    struct Row: Equatable {
        var logo: String
        var name: String
        var weekly: Line
        var five: Line?            // nil when the service could not be read (only the weekly line with its status)
        var staleText: String?     // "6시간 전 값"
        var detail: String         // tooltip
    }

    // "방금 읽은 값" / "12분 전 값" / "6시간 전 값" / "2일 전 값"
    static func ageText(_ t: Date?, now: Date = Date()) -> String? {
        guard let t = t else { return nil }
        let m = Int(max(0, now.timeIntervalSince(t)) / 60)
        if m < 1 { return "방금 읽은 값" }
        if m < 60 { return "\(m)분 전 값" }
        if m < 48 * 60 { return "\(m / 60)시간 전 값" }
        return "\(m / 1440)일 전 값"
    }

    static func row(_ q: Quota, logo: String, name: String, ag: Bool, now: Date = Date(), tz: TimeZone = .current) -> Row {
        if !q.ok {
            let st = shortStatus(q)
            let w = Line(label: "주간", fraction: 0, value: "—", reset: st, tone: .off, emphasis: false, muted: true)
            return Row(logo: logo, name: name, weekly: w, five: nil, staleText: nil, detail: name + ": " + (q.error ?? st))
        }
        let stale = Merge.showStale(q, ag: ag)
        var tips: [String] = []
        // weekly
        let wReset = q.resetsAt.map { when($0, now: now, tz: tz) } ?? ""
        var weekly: Line
        if q.remaining <= 0 {
            weekly = Line(label: "주간", fraction: 0, value: "다 씀", reset: wReset, tone: .off, emphasis: !stale, muted: false)
            tips.append("주간 다 씀" + (wReset.isEmpty ? "" : ", " + wReset + "에 다시 차요"))
        } else {
            weekly = Line(label: "주간", fraction: min(1, q.remaining / 100), value: Usage.remainingNumber(q.remaining) + "%",
                          reset: wReset, tone: tone(q.remaining), emphasis: false, muted: false)
            tips.append("주간 " + Usage.remainingNumber(q.remaining) + "% 남음" + (wReset.isEmpty ? "" : ", 초기화 " + wReset))
        }
        // the 5-hour window (or the service's other short window); "없음" when the service sends none
        let ws = MenuBarStrip.others(q)
        var five: Line
        if let w = ws.first(where: { $0.label == "5시간" }) ?? ws.first {
            var reset = ""
            if w.remaining < 100, let r = w.reset { reset = r > now ? MenuBarStrip.clock(r, tz: tz) : "곧" }
            if MenuBarStrip.isUsedUp(w) {
                five = Line(label: w.label, fraction: 0, value: "다 씀", reset: reset, tone: .off, emphasis: !stale, muted: false)
                tips.append(w.label + " 다 씀" + (reset.isEmpty ? "" : reset == "곧" ? ", 곧 다시 차요" : ", " + reset + "에 다시 차요"))
            } else {
                five = Line(label: w.label, fraction: min(1, w.remaining / 100), value: Usage.remainingNumber(w.remaining) + "%",
                            reset: reset, tone: tone(w.remaining), emphasis: false, muted: false)
                tips.append(w.label + " " + Usage.remainingNumber(w.remaining) + "% 남음" + (reset.isEmpty || reset == "곧" ? "" : ", " + reset + "에 다시 차요"))
            }
        } else {
            five = Line(label: "5시간", fraction: 0, value: "없음", reset: "", tone: .off, emphasis: false, muted: true)
            tips.append("5시간 한도는 이 서비스가 지금 알려 주지 않아요")
        }
        var staleText: String?
        if stale {
            staleText = ageText(q.lastOk, now: now) ?? "오래된 값"
            weekly.tone = weekly.tone == .off ? .off : .stale; five.tone = five.tone == .off ? .off : .stale
            tips.append("값이 오래됐어요" + (q.failing ? ": " + (q.error ?? "") : ""))
        }
        if let a = q.account { tips.append("계정 " + (DashboardFeed.mask(a) ?? a)) }
        return Row(logo: logo, name: name, weekly: weekly, five: five, staleText: staleText, detail: tips.joined(separator: "\n"))
    }

    // Codex, Claude, Grok, Gemini 4 Argon, Antigravity (the menu bar's order); Antigravity rows only once read
    static let rowNames = ["Codex", "Claude", "Grok", "Gemini 4 Argon", "Antigravity"]
    static let rowLogos = ["codex", "claude", "grok", "gemini", "antigravity"]
    static func rows(main: [Quota], ag: [Quota], loaded: Bool, now: Date = Date(), tz: TimeZone = .current) -> [Row] {
        func waiting(_ i: Int) -> Row {
            let q = Quota(); q.error = "확인 전"
            return row(q, logo: rowLogos[i], name: rowNames[i], ag: i >= 3, now: now, tz: tz)
        }
        guard loaded else { return (0..<4).map(waiting) }
        var out: [Row] = main.prefix(3).enumerated().map { i, q in row(q, logo: rowLogos[i], name: rowNames[i], ag: false, now: now, tz: tz) }
        if ag.isEmpty { out.append(waiting(3)) }
        for (j, q) in ag.prefix(2).enumerated() { out.append(row(q, logo: rowLogos[3 + j], name: rowNames[3 + j], ag: true, now: now, tz: tz)) }
        return out
    }

    // a column is ~70pt wide: the full message goes to the tooltip
    static func shortStatus(_ q: Quota) -> String {
        if q.noLogin { return "로그인 필요" }
        if q.notInstalled { return "설치 안 됨" }
        guard let e = q.error else { return "확인 전" }
        if e == "확인 전" { return e }
        if e.hasPrefix("로그인 만료") { return "다시 로그인" }
        if e.hasPrefix("토큰 갱신 대기") { return "갱신 대기" }
        if e.hasPrefix("접근 거부") { return "접근 거부" }
        if e.hasPrefix("키체인") { return "키체인 허용 필요" }
        if q.transient { return "연결 실패" }
        return "읽기 실패"
    }

    // "오늘 밤 12시", "오늘 15:35", "내일 15:35", "월 14:58" (within 3 days), "11/4 15:35", "11/6" (midnight)
    static func when(_ d: Date, now: Date = Date(), tz: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let diff = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 0
        let c = cal.dateComponents([.month, .day, .hour, .minute, .weekday], from: d)
        let hm = String(format: "%02d:%02d", c.hour!, c.minute!)
        if diff == 1 && hm == "00:00" { return "오늘 밤 12시" }
        if diff == 0 { return "오늘 " + hm }
        if diff == 1 { return "내일 " + hm }
        if diff >= 2 && diff <= 3 { return ["일", "월", "화", "수", "목", "금", "토"][c.weekday! - 1] + " " + hm }
        return "\(c.month!)/\(c.day!)" + (hm == "00:00" ? "" : " " + hm)
    }

    // "방금 확인, 계정 2개": accounts = distinct signed-in accounts behind Codex/Claude/Grok (0 = left out)
    static func header(lastCheck: Date?, main: [Quota], now: Date = Date()) -> String {
        var parts: [String] = []
        if let t = lastCheck {
            let m = Int(now.timeIntervalSince(t) / 60)
            parts.append(m < 1 ? "방금 확인" : m < 60 ? "\(m)분 전 확인" : "\(m / 60)시간 전 확인")
        }
        var ids = Set<String>()
        for q in main.prefix(3) where !q.noLogin { if let k = q.accountKey ?? q.credKey { ids.insert(k) } }
        if !ids.isEmpty { parts.append("계정 \(ids.count)개") }
        return parts.joined(separator: ", ")
    }

    // ---- "지금 할 일": the dashboard's first item (client.cjs liveLong + convName + compact) ----
    struct Todo: Equatable { var name: String; var tokens: String }

    static func todo(snapshot: [String: Any]?, names: [String: String], helpers: Set<String>, now: Date = Date()) -> Todo? {
        guard let ds = snapshot?["datasets"] as? [[String: Any]] else { return nil }
        var best: (ctx: Double, session: String, project: String?)?
        for d in ds {
            guard let e = d["efficiency"] as? [String: Any], e["status"] as? String == "observed",
                  let recent = e["recentSessions"] as? [[String: Any]] else { continue }
            for x in recent {
                let ctx = Usage.num(x, "lastContext")
                guard let s = x["session"] as? String, !ctx.isNaN, ctx >= 400000,
                      let at = (x["lastAt"]).flatMap({ Usage.parseTime($0) }) else { continue }
                let ago = now.timeIntervalSince(at)
                if ago < 0 || ago >= 6 * 3600 || helpers.contains(s) { continue }
                if best == nil || ctx > best!.ctx { best = (ctx, s, x["project"] as? String) }
            }
        }
        guard let b = best else { return nil }
        let name: String
        if let n = names[b.session] { name = "\"" + n + "\"" }
        else if let p = b.project, p != "unknown" { name = (names[p] ?? "이름 없는 폴더") + " 대화" }
        else { name = "이름 없는 대화" }
        return Todo(name: name, tokens: compact(b.ctx) + " 토큰")
    }

    // dashboard compact(): 1억 and 1만 units, one decimal below 100 of the unit
    static func compact(_ n: Double) -> String {
        func f(_ x: Double) -> String {
            let nf = NumberFormatter(); nf.locale = Locale(identifier: "ko_KR"); nf.numberStyle = .decimal
            nf.maximumFractionDigits = x >= 100 ? 0 : 1; nf.roundingMode = .halfUp
            return nf.string(from: NSNumber(value: x)) ?? String(x)
        }
        if n >= 1e8 { return f(n / 1e8) + "억" }
        if n >= 1e4 { return f(n / 1e4) + "만" }
        let nf = NumberFormatter(); nf.locale = Locale(identifier: "ko_KR"); nf.numberStyle = .decimal
        return nf.string(from: NSNumber(value: n)) ?? String(Int(n))
    }

    // reads the dashboard data the 30-minute refresh writes; nil when it is not set up or has nothing
    static func loadTodo(now: Date = Date()) -> Todo? {
        let snapPath = (Paths.data as NSString).appendingPathComponent("snapshot.json")
        let namesPath = (Paths.data as NSString).appendingPathComponent("local-names.json")
        guard let snap = Usage.readJson(snapPath) else { return nil }
        let ln = Usage.readJson(namesPath)
        let names = (ln?["names"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
        let helpers = Set((ln?["helpers"] as? [Any])?.compactMap { $0 as? String } ?? [])
        return todo(snapshot: snap, names: names, helpers: helpers, now: now)
    }

    // ---- logos ----
    // light screens use the dark-ink variants where they exist (codex-dark.png, grok-dark.png)
    static func logoFile(_ key: String, dark: Bool) -> String {
        if !dark && (key == "codex" || key == "grok") { return key + "-dark" }
        return key
    }
    private static var logoCache: [String: NSImage] = [:]
    static func logo(_ key: String, dark: Bool) -> NSImage? {
        let file = logoFile(key, dark: dark)
        if let hit = logoCache[file] { return hit }
        var candidates: [String] = []
        if let r = Bundle.main.resourcePath { candidates.append((r as NSString).appendingPathComponent("logos/\(file).png")) }
        if let a = ProcessInfo.processInfo.environment["UG_ASSETS"] { candidates.append((a as NSString).appendingPathComponent("\(file).png")) }
        for p in candidates { if let img = NSImage(contentsOfFile: p) { logoCache[file] = img; return img } }
        return nil
    }

    // the menu bar ring: 16pt, line 2, logo of the most urgent service; grey empty ring when nothing was read
    static func menuBarRing(remaining: Double?, logoKey: String?, dark: Bool) -> NSImage {
        let size: CGFloat = 16, lw: CGFloat = 2
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let r = (size - lw) / 2, c = NSPoint(x: rect.midX, y: rect.midY)
            let track = NSBezierPath(); track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
            track.lineWidth = lw
            (dark ? NSColor(white: 1, alpha: remaining == nil ? 0.35 : 0.22) : NSColor(white: 0, alpha: remaining == nil ? 0.3 : 0.14)).setStroke()
            track.stroke()
            if let rem = remaining {
                let frac = max(0, min(1, rem / 100))
                let arc = NSBezierPath()
                // 12 o'clock, clockwise
                arc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 360 * CGFloat(max(frac, 0.0001)), clockwise: true)
                arc.lineWidth = lw; arc.lineCapStyle = .round
                color(tone(rem)).setStroke(); arc.stroke()
                if let k = logoKey, let l = logo(k, dark: dark) {
                    l.draw(in: NSRect(x: 4, y: 4, width: 8, height: 8), from: .zero, operation: .sourceOver, fraction: 1)
                }
            }
            return true
        }
        return img
    }
}
