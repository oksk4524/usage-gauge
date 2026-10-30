import AppKit
import Foundation

// Menu bar variant C, revised 2026-10-30: for every service with a value, a filled monochrome logo, a small
// vertical remaining bar and the number left (no % sign). Fixed order Codex, Claude, Grok, then the Antigravity
// group as two items like Windows: Gemini 4 Argon (Gemini star) and the rest of Antigravity (Gemini general and
// Claude and GPT pools, Antigravity logo). Services without a value are hidden. A used-up service is not dimmed: its
// bar is an empty outline and, instead of "0", it shows when it fills again ("월", or "14시" within 24 hours).
// Drawn as one template image of vector glyphs, so macOS tints it for light and dark menu bars by itself.

enum MenuBarStrip {
    struct Entry: Equatable {
        var logo: String       // glyph key: codex, claude, grok, gemini, antigravity
        var name: String       // tooltip name
        var window: String     // "주간", "5시간": the window that limits right now
        var remaining: Double  // 0...100
        var reset: Date?
        var stale: Bool
    }

    static let shortNames = ["Codex", "Claude", "Grok"]
    static let order = ["codex", "claude", "grok", "gemini", "antigravity"]

    // the limit that actually binds: the lowest remaining among the service's general windows
    // (Codex 5-hour + weekly, Claude 5-hour + weekly; model-only pools like weekly Opus are left out).
    // On a tie the later reset wins, since that is when the service is usable again.
    static func binding(_ q: Quota) -> (window: String, remaining: Double, reset: Date?) {
        var best: (window: String, remaining: Double, reset: Date?) = ("주간", q.remaining, q.resetsAt)
        for w in q.windows {
            let label: String
            switch w.key {
            case "seven_day", "weekly": label = "주간"
            case "five_hour": label = "5시간"
            case "primary_window", "secondary_window":
                if w.seconds == 604800 { label = "주간" }
                else if w.seconds == 18000 { label = "5시간" }
                else if !w.seconds.isNaN && w.seconds > 0 {
                    label = w.seconds.truncatingRemainder(dividingBy: 86400) == 0 ? "\(Int(w.seconds / 86400))일" : "\(Int((w.seconds / 3600).rounded()))시간"
                } else { continue }
            default: continue
            }
            if w.used.isNaN { continue }
            let rem = max(0, min(100, 100 - w.used))
            let laterReset = (w.reset ?? .distantPast) > (best.reset ?? .distantPast)
            if rem < best.remaining - 0.0001 || (abs(rem - best.remaining) <= 0.0001 && laterReset) { best = (label, rem, w.reset) }
        }
        return best
    }

    // main = Codex, Claude, Grok; ag = Antigravity.fetch() order [Gemini 4 Argon, rest of Antigravity].
    // The order is fixed (no longer sorted by what is usable); services without a value are left out.
    static func entries(main: [Quota], ag: [Quota]) -> [Entry] {
        var out: [Entry] = []
        func add(_ q: Quota, _ logo: String, _ name: String, isAg: Bool) {
            guard q.ok else { return }
            let b = binding(q)
            out.append(Entry(logo: logo, name: name, window: b.window, remaining: b.remaining, reset: b.reset,
                             stale: Merge.showStale(q, ag: isAg)))
        }
        for (i, q) in main.prefix(3).enumerated() { add(q, order[i], shortNames[i], isAg: false) }
        if ag.count >= 1 { add(ag[0], "gemini", Antigravity.geminiName, isAg: true) }
        if ag.count >= 2 { add(ag[1], "antigravity", Antigravity.otherName, isAg: true) }
        return out
    }

    static let weekdays = ["일", "월", "화", "수", "목", "금", "토"]
    static func calendar(_ tz: TimeZone) -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c }

    // menu bar text for a used-up service: the local weekday it fills again ("월"), or the hour when that is
    // less than 24 hours away ("14시"); "곧" once the reset time has passed
    static func refillLabel(_ reset: Date?, now: Date = Date(), tz: TimeZone = .current) -> String {
        guard let r = reset else { return "0" }
        let left = r.timeIntervalSince(now)
        if left <= 0 { return "곧" }
        let c = calendar(tz)
        if left < 86400 { return "\(c.component(.hour, from: r))시" }
        return weekdays[c.component(.weekday, from: r) - 1]
    }

    // tooltip time: "월 12:00"; within 24 hours "오늘 14:58" / "내일 09:00"
    static func refillTime(_ r: Date, now: Date = Date(), tz: TimeZone = .current) -> String {
        let c = calendar(tz)
        let hm = String(format: "%02d:%02d", c.component(.hour, from: r), c.component(.minute, from: r))
        if r.timeIntervalSince(now) < 86400 {
            if c.isDate(r, inSameDayAs: now) { return "오늘 " + hm }
            if let t = c.date(byAdding: .day, value: 1, to: now), c.isDate(r, inSameDayAs: t) { return "내일 " + hm }
        }
        return weekdays[c.component(.weekday, from: r) - 1] + " " + hm
    }

    // "2일 16시간 뒤", "3시간 20분 뒤", "15분 뒤"
    static func until(_ d: Date, now: Date = Date()) -> String {
        let mins = Int((d.timeIntervalSince(now) / 60).rounded())
        if mins <= 0 { return "곧" }
        if mins < 60 { return "\(mins)분 뒤" }
        if mins < 24 * 60 { return mins % 60 == 0 ? "\(mins / 60)시간 뒤" : "\(mins / 60)시간 \(mins % 60)분 뒤" }
        var days = mins / 1440, hours = Int((Double(mins % 1440) / 60).rounded())
        if hours == 24 { days += 1; hours = 0 }
        return hours == 0 ? "\(days)일 뒤" : "\(days)일 \(hours)시간 뒤"
    }

    // one line per item, in the menu bar order:
    // "Codex 주간 37% 남음" / "Claude 주간 다 씀, 월 12:00에 다시 차요"
    static func tooltip(_ es: [Entry], now: Date = Date(), tz: TimeZone = .current) -> String {
        es.map { e in
            var s = e.name + " " + e.window + " "
            if e.remaining <= 0 {
                s += "다 씀"
                if let r = e.reset { s += r > now ? ", " + refillTime(r, now: now, tz: tz) + "에 다시 차요" : ", 곧 다시 차요" }
            } else { s += Usage.remainingNumber(e.remaining) + "% 남음" }
            return e.stale ? s + " (오래된 값)" : s
        }.joined(separator: "\n")
    }

    static func numberText(_ e: Entry, now: Date = Date(), tz: TimeZone = .current) -> String {
        e.remaining <= 0 ? refillLabel(e.reset, now: now, tz: tz) : Usage.remainingNumber(e.remaining)
    }

    // ---- drawing (points; approved mock at 2x: logo 32px, bar 7x25px with a 2px outline, gaps 7px,
    // between services 20px, 13pt medium text) ----
    static let glyphSize: CGFloat = 16, barW: CGFloat = 3.5, barH: CGFloat = 12.5, gap: CGFloat = 3.5, between: CGFloat = 10
    static let height: CGFloat = 22, outline: CGFloat = 1
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

    // SVG path data (M L H V C S Q Z, absolute or relative) -> NSBezierPath in SVG units, cached per glyph
    private static var pathCache: [String: NSBezierPath] = [:]
    static func svgPath(_ d: String) -> NSBezierPath {
        let p = NSBezierPath()
        var nums: [CGFloat] = [], cmds: [(Character, [CGFloat])] = []
        var cmd: Character?, num = ""
        func flushNum() { if !num.isEmpty, let v = Double(num) { nums.append(CGFloat(v)) }; num = "" }
        func flushCmd() { flushNum(); if let c = cmd { cmds.append((c, nums)) }; nums = [] }
        var prev: Character = " "
        for ch in d {
            if ch.isLetter && ch != "e" && ch != "E" { flushCmd(); cmd = ch }
            else if ch == "-" && !(prev == "e" || prev == "E") { flushNum(); num = "-" }
            else if ch == "." && num.contains(".") { flushNum(); num = "." }
            else if ch.isNumber || ch == "." || ch == "e" || ch == "E" || ch == "-" { num.append(ch) }
            else { flushNum() }
            prev = ch
        }
        flushCmd()
        var cur = CGPoint.zero, start = CGPoint.zero, lastCtrl: CGPoint?
        for (c, a) in cmds {
            let rel = c.isLowercase
            func pt(_ i: Int) -> CGPoint { CGPoint(x: a[i] + (rel ? cur.x : 0), y: a[i + 1] + (rel ? cur.y : 0)) }
            switch c.uppercased() {
            case "M":
                var i = 0
                while i + 1 < a.count {
                    let q = pt(i)
                    if i == 0 { p.move(to: q); start = q } else { p.line(to: q) }
                    cur = q; i += 2
                }
                lastCtrl = nil
            case "L":
                var i = 0
                while i + 1 < a.count { let q = pt(i); p.line(to: q); cur = q; i += 2 }
                lastCtrl = nil
            case "H":
                for v in a { cur = CGPoint(x: rel ? cur.x + v : v, y: cur.y); p.line(to: cur) }
                lastCtrl = nil
            case "V":
                for v in a { cur = CGPoint(x: cur.x, y: rel ? cur.y + v : v); p.line(to: cur) }
                lastCtrl = nil
            case "C":
                var i = 0
                while i + 5 < a.count {
                    let c1 = pt(i), c2 = pt(i + 2), q = pt(i + 4)
                    p.curve(to: q, controlPoint1: c1, controlPoint2: c2); lastCtrl = c2; cur = q; i += 6
                }
            case "S":
                var i = 0
                while i + 3 < a.count {
                    let c1 = lastCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                    let c2 = pt(i), q = pt(i + 2)
                    p.curve(to: q, controlPoint1: c1, controlPoint2: c2); lastCtrl = c2; cur = q; i += 4
                }
            case "Q":
                var i = 0
                while i + 3 < a.count {
                    let c = pt(i), q = pt(i + 2)
                    let c1 = CGPoint(x: cur.x + 2 / 3 * (c.x - cur.x), y: cur.y + 2 / 3 * (c.y - cur.y))
                    let c2 = CGPoint(x: q.x + 2 / 3 * (c.x - q.x), y: q.y + 2 / 3 * (c.y - q.y))
                    p.curve(to: q, controlPoint1: c1, controlPoint2: c2); lastCtrl = nil; cur = q; i += 4
                }
            case "Z":
                p.close(); cur = start; lastCtrl = nil
            default: continue
            }
        }
        return p
    }
    static func glyphPath(_ key: String) -> NSBezierPath? {
        if let hit = pathCache[key] { return hit }
        guard let g = MenuBarGlyphs.named(key) else { return nil }
        let p = svgPath(g.d); pathCache[key] = p
        return p
    }

    // the glyph fitted into rect (aspect kept, centred), filled and, where the mock thickens it, outlined
    static func drawGlyph(_ key: String, in rect: NSRect) {
        guard let g = MenuBarGlyphs.named(key), let base = glyphPath(key), let p = base.copy() as? NSBezierPath else { return }
        let vb = g.viewBox, s = min(rect.width / vb.width, rect.height / vb.height)
        let ox = rect.minX + (rect.width - vb.width * s) / 2, oy = rect.minY + (rect.height - vb.height * s) / 2
        // SVG y runs down: x' = ox + (x - minX) s, y' = oy + (maxY - y) s
        p.transform(using: AffineTransform(m11: s, m12: 0, m21: 0, m22: -s, tX: ox - vb.minX * s, tY: oy + vb.maxY * s))
        p.windingRule = g.evenOdd ? .evenOdd : .nonZero
        NSColor.black.set()
        p.fill()
        if g.stroke > 0 { p.lineWidth = g.stroke * s; p.lineJoinStyle = .round; p.stroke() }
    }

    static func image(_ es: [Entry], now: Date = Date()) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let texts = es.map { numberText($0, now: now) }
        let widths = texts.map { ceil(($0 as NSString).size(withAttributes: attrs).width) }
        var total: CGFloat = 0
        for (i, w) in widths.enumerated() { total += glyphSize + gap + barW + gap + w + (i > 0 ? between : 0) }
        let size = NSSize(width: max(1, ceil(total)), height: height)
        let img = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            let mid = height / 2
            for (i, e) in es.enumerated() {
                if i > 0 { x += between }
                drawGlyph(e.logo, in: NSRect(x: x, y: mid - glyphSize / 2, width: glyphSize, height: glyphSize))
                x += glyphSize + gap
                let track = NSRect(x: x, y: (mid - barH / 2).rounded(), width: barW, height: barH)
                NSColor.black.setFill(); NSColor.black.setStroke()
                let frame = NSBezierPath(roundedRect: track.insetBy(dx: outline / 2, dy: outline / 2), xRadius: 0.75, yRadius: 0.75)
                frame.lineWidth = outline; frame.stroke()
                let frac = CGFloat(max(0, min(1, e.remaining / 100)))
                if frac > 0 {
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(roundedRect: track, xRadius: 1.25, yRadius: 1.25).addClip()
                    NSRect(x: track.minX, y: track.minY, width: barW, height: max(1, barH * frac)).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                x += barW + gap
                // text centred on the bar: baseline = middle - half the cap height; draw(at:) takes the line's bottom
                let baseline = (2 * (mid - font.capHeight / 2)).rounded() / 2
                (texts[i] as NSString).draw(at: NSPoint(x: x, y: baseline + font.descender), withAttributes: attrs)
                x += widths[i]
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
