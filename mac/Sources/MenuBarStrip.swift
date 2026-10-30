import AppKit
import Foundation

// Menu bar, revised 2026-10-30: for every service with a value, a monochrome logo, a small
// vertical remaining bar and the number left (no % sign). Fixed order Codex, Claude, Grok, then the Antigravity
// group as two items like Windows: Gemini 4 Argon (Gemini star) and the rest of Antigravity (Gemini general and
// Claude and GPT pools, Antigravity logo). Services without a value are hidden. A used-up service is not dimmed: its
// bar is an empty faint track and, instead of "0", it shows when it fills again ("월", or "14시" within 24 hours).
// Variant A (2026-10-30): logos at natural weight, a 2 px bar over a faint track, the number in 13 pt medium.
// Drawn as one template image, so macOS tints it for light and dark menu bars by itself.
// Revised 2026-10-30 (owner's choice): the number and bar are the weekly limit. While a 5-hour window is used up
// and the weekly one still has room, the bar shows only its empty track and the 5-hour refill hour follows the
// weekly number ("99 1시"), so a temporary block is visible without hiding the item.

enum MenuBarStrip {
    struct Entry: Equatable {
        var logo: String       // glyph key: codex, claude, grok, gemini, antigravity
        var name: String       // tooltip name
        var window: String     // "주간": the bar and number always show the weekly limit
        var remaining: Double  // 0...100
        var reset: Date?
        var stale: Bool
        var blocked: Window? = nil   // a shorter window (5-hour) used up while the weekly one still has room
    }

    // one limit window of a service: "주간", "5시간", or another length ("1일")
    struct Window: Equatable {
        var label: String
        var remaining: Double  // 0...100
        var reset: Date?
    }

    static let shortNames = ["Codex", "Claude", "Grok"]
    static let order = ["codex", "claude", "grok", "gemini", "antigravity"]

    // revised 2026-10-30 (owner's choice): the menu bar number and the popover ring both show the WEEKLY limit.
    // Quota.remaining already is the weekly value: Claude seven_day, Codex the 604800 s window, Grok its weekly
    // period, an Antigravity item the lowest of its weekly buckets (5-hour buckets never count there).
    static func weekly(_ q: Quota) -> Window { Window(label: "주간", remaining: q.remaining, reset: q.resetsAt) }

    // the name of a general window; nil for weekly ones and model-only pools (weekly Opus, Sonnet)
    static func shortLabel(_ w: UsageWindow) -> String? {
        switch w.key {
        case "five_hour": return "5시간"
        case "primary_window", "secondary_window":
            if w.seconds == 604800 { return nil }
            if w.seconds == 18000 { return "5시간" }
            if !w.seconds.isNaN && w.seconds > 0 {
                return w.seconds.truncatingRemainder(dividingBy: 86400) == 0 ? "\(Int(w.seconds / 86400))일" : "\(Int((w.seconds / 3600).rounded()))시간"
            }
            return nil
        default: return nil
        }
    }

    // the service's other general windows (Codex and Claude 5-hour, Antigravity 5-hour buckets), one per length:
    // the lowest remaining, on a tie the later reset (when it is usable again)
    static func others(_ q: Quota) -> [Window] {
        var out: [Window] = []
        for w in q.windows {
            guard let label = shortLabel(w), !w.used.isNaN else { continue }
            let rem = max(0, min(100, 100 - w.used))
            if let i = out.firstIndex(where: { $0.label == label }) {
                let o = out[i]
                if rem < o.remaining - 0.0001 || (abs(rem - o.remaining) <= 0.0001 && (w.reset ?? .distantPast) > (o.reset ?? .distantPast)) {
                    out[i] = Window(label: label, remaining: rem, reset: w.reset)
                }
            } else { out.append(Window(label: label, remaining: rem, reset: w.reset)) }
        }
        return out
    }

    // a shorter window counts as used up below 2% (the service stops answering before an exact 0)
    static let usedUpBelow = 2.0
    static func isUsedUp(_ w: Window) -> Bool { w.remaining < usedUpBelow }

    // temporarily blocked: the weekly limit still has room but a shorter window is used up; the latest refill wins
    static func blocked(_ q: Quota) -> Window? {
        guard q.remaining > 0 else { return nil }
        return others(q).filter(isUsedUp).max { ($0.reset ?? .distantPast) < ($1.reset ?? .distantPast) }
    }

    // main = Codex, Claude, Grok; ag = Antigravity.fetch() order [Gemini 4 Argon, rest of Antigravity].
    // The order is fixed (no longer sorted by what is usable); services without a value are left out.
    static func entries(main: [Quota], ag: [Quota]) -> [Entry] {
        var out: [Entry] = []
        func add(_ q: Quota, _ logo: String, _ name: String, isAg: Bool) {
            guard q.ok else { return }
            let w = weekly(q)
            out.append(Entry(logo: logo, name: name, window: w.label, remaining: w.remaining, reset: w.reset,
                             stale: Merge.showStale(q, ag: isAg), blocked: blocked(q)))
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

    // "01:19": a shorter window always refills within a day, so the clock time alone is clear
    static func clock(_ r: Date, tz: TimeZone = .current) -> String {
        let c = calendar(tz)
        return String(format: "%02d:%02d", c.component(.hour, from: r), c.component(.minute, from: r))
    }

    // "5시간 다 씀, 01:19에 다시 차요"
    static func blockedLine(_ w: Window, now: Date = Date(), tz: TimeZone = .current) -> String {
        var s = w.label + " 다 씀"
        if let r = w.reset { s += r > now ? ", " + clock(r, tz: tz) + "에 다시 차요" : ", 곧 다시 차요" }
        return s
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
    // "Codex 주간 37% 남음" / "Claude 주간 다 씀, 월 12:00에 다시 차요";
    // a used-up 5-hour window adds a line under its item: "5시간 다 씀, 01:19에 다시 차요"
    static func tooltip(_ es: [Entry], now: Date = Date(), tz: TimeZone = .current) -> String {
        es.map { e in
            var s = e.name + " " + e.window + " "
            if e.remaining <= 0 {
                s += "다 씀"
                if let r = e.reset { s += r > now ? ", " + refillTime(r, now: now, tz: tz) + "에 다시 차요" : ", 곧 다시 차요" }
            } else { s += Usage.remainingNumber(e.remaining) + "% 남음" }
            if e.stale { s += " (오래된 값)" }
            if let b = e.blocked { s += "\n" + blockedLine(b, now: now, tz: tz) }
            return s
        }.joined(separator: "\n")
    }

    static func numberText(_ e: Entry, now: Date = Date(), tz: TimeZone = .current) -> String {
        e.remaining <= 0 ? refillLabel(e.reset, now: now, tz: tz) : Usage.remainingNumber(e.remaining)
    }

    // a 5-hour-blocked item keeps its weekly number and adds when the short window fills again ("1시", "곧"),
    // in the same style as a used-up item's refill hour; nil when it is not blocked or the reset is unknown
    static func blockedText(_ e: Entry, now: Date = Date(), tz: TimeZone = .current) -> String? {
        guard let b = e.blocked, b.reset != nil else { return nil }
        return refillLabel(b.reset, now: now, tz: tz)
    }

    // the bar shows the weekly share, except while a 5-hour window blocks the service: then only the empty track
    static func barRemaining(_ e: Entry) -> Double { e.blocked != nil ? 0 : e.remaining }

    // ---- drawing, variant A (approved mock menubar-mock3, 2026-10-30; all in points = 1x pixels) ----
    // logo at natural weight 15 px (Gemini star, Antigravity 14 px) -> 3 -> bar 2x12 filled from the bottom over a
    // faint 30% track -> 3 -> number in 13 pt medium (refill day/hour 14 pt); 10 between services. Every origin is a whole point, so the 1x
    // menu bar gets sharp pixels; the logos carry their own 2x masks for Retina.
    // The mock is a 24 px bar; this image is 22 pt tall and sits 1 pt below the bar top, so mock row r = image row r - 1.
    static let gap: CGFloat = 3, barW: CGFloat = 2, barH: CGFloat = 12, between: CGFloat = 10
    static let height: CGFloat = 22, trackAlpha: CGFloat = 0.3
    static let glyphTop: CGFloat = 4      // mock row 5: top of the logo cell
    static let barTop: CGFloat = 6        // mock row 7..18
    static let baselineTop: CGFloat = 16  // mock baseline 17
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    // the refill day or hour of a used-up service ("월", "14시", "곧") is 1 pt larger, so the Hangul stays legible on a
    // 1x screen; on the same baseline its ink centre (10.6 px from the top) matches the digits' (10.5 px)
    static let labelFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    static func textFont(_ text: String) -> NSFont { text.allSatisfy(\.isNumber) ? font : labelFont }

    // filled bar height in points: 12 x remaining, at least 2 so a sliver still shows; 0 when used up
    static func fillHeight(_ remaining: Double) -> CGFloat {
        remaining <= 0 ? 0 : max(2, (barH * CGFloat(min(100, remaining)) / 100).rounded())
    }

    static func layoutWidth(_ es: [Entry], texts: [String], widths: [CGFloat], extraWidths: [CGFloat]? = nil) -> CGFloat {
        var total: CGFloat = 0
        for (i, e) in es.enumerated() {
            let adv = CGFloat(MenuBarGlyphs.named(e.logo)?.advance ?? 15)
            let extra = extraWidths.map { $0[i] > 0 ? gap + $0[i] : 0 } ?? 0
            total += (i > 0 ? between : 0) + adv + gap + barW + gap + widths[i] + extra
        }
        return total
    }

    static func image(_ es: [Entry], now: Date = Date()) -> NSImage {
        let texts = es.map { numberText($0, now: now) }
        let attrs = texts.map { [NSAttributedString.Key.font: textFont($0), .foregroundColor: NSColor.black] as [NSAttributedString.Key: Any] }
        let widths = texts.indices.map { ceil((texts[$0] as NSString).size(withAttributes: attrs[$0]).width) }
        // the refill hour of a 5-hour-blocked item, after its weekly number
        let blockedTexts = es.map { blockedText($0, now: now) }
        let blockedAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.black]
        let extraWidths = blockedTexts.map { t in t.map { ceil(($0 as NSString).size(withAttributes: blockedAttrs).width) } ?? 0 }
        let size = NSSize(width: max(1, layoutWidth(es, texts: texts, widths: widths, extraWidths: extraWidths)), height: height)
        let img = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            for (i, e) in es.enumerated() {
                if i > 0 { x += between }
                if let g = MenuBarGlyphs.named(e.logo), let gi = MenuBarGlyphs.image(e.logo) {
                    let r = NSRect(x: x, y: height - glyphTop - CGFloat(g.cellH), width: CGFloat(g.cellW), height: CGFloat(g.cellH))
                    gi.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                    x += CGFloat(g.advance)
                } else { x += 15 }
                x += gap
                // bar: faint track, then the remaining part from the bottom (no outline)
                let barY = height - barTop - barH
                NSColor.black.withAlphaComponent(trackAlpha).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: barY, width: barW, height: barH), xRadius: 1, yRadius: 1).fill()
                let fh = fillHeight(barRemaining(e))
                if fh > 0 {
                    NSColor.black.setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: barY, width: barW, height: fh), xRadius: 1, yRadius: 1).fill()
                }
                x += barW + gap
                // number (or refill day/hour) at full ink; draw(at:) takes the line bottom = baseline + descender
                (texts[i] as NSString).draw(at: NSPoint(x: x, y: height - baselineTop + textFont(texts[i]).descender), withAttributes: attrs[i])
                x += widths[i]
                if let t = blockedTexts[i] {
                    x += gap
                    (t as NSString).draw(at: NSPoint(x: x, y: height - baselineTop + labelFont.descender), withAttributes: blockedAttrs)
                    x += extraWidths[i]
                }
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
