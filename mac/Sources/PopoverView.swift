import AppKit
import SwiftUI

// The popover of the approved design: "남은 한도" + four ring gauges, "지금 할 일" (only when there is one),
// and a footer of text buttons. Colors follow the system light/dark mode.

final class PopoverModel: ObservableObject {
    @Published var header = ""
    @Published var gauges: [Design.Gauge] = []
    @Published var rows: [Design.Row] = []
    @Published var todo: Design.Todo?
    @Published var busy = false
    @Published var refreshStatus: String?
    @Published var refreshFailed = false
    @Published var habitRunning = false
    @Published var habitWait: String?   // "N분 뒤에 다시 돌릴 수 있어요" within 10 min of the last run
    // hover and spin state of the footer buttons (an object, since this SDK's @State needs a macro plugin the
    // command line tools don't ship)
    let detailsUI = ButtonUI(), habitUI = ButtonUI(), refreshUI = ButtonUI()
    var onDetails: () -> Void = {}
    var onHabit: () -> Void = {}
    var onRefresh: () -> Void = {}
}

final class ButtonUI: ObservableObject {
    @Published var hover = false
    @Published var spins = 0.0
}

extension Color { init(_ c: NSColor) { self.init(nsColor: c) } }

struct RingView: View {
    let g: Design.Gauge
    let scheme: Palette.Scheme
    let dark: Bool
    var body: some View {
        ZStack {
            Circle().stroke(Color(scheme.track), lineWidth: 4.5)
            if g.tone != .off {
                // 12 o'clock start, clockwise, round ends; a used-up ring keeps a red dot
                Circle()
                    .trim(from: 0, to: max(g.fraction, 0.0001))
                    .stroke(Color(Design.color(g.tone)), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if let img = Design.logo(g.logo, dark: dark) {
                Image(nsImage: img).resizable().interpolation(.high).frame(width: 20, height: 20)
                    .opacity(g.tone == .off ? 0.45 : 1)
            }
        }
        .padding(2.25)                 // the stroke stays inside 52pt: radius 23.75
        .frame(width: 52, height: 52)
    }
}

struct GaugeColumn: View {
    let g: Design.Gauge
    let scheme: Palette.Scheme
    let dark: Bool
    var body: some View {
        VStack(spacing: 0) {
            RingView(g: g, scheme: scheme, dark: dark)
            Group {
                if case .value = g.state {
                    Text("\(Text(g.percentText).font(.system(size: 17, weight: .bold)).foregroundColor(Color(scheme.fg)))\(Text("%").font(.system(size: 11, weight: .semibold)).foregroundColor(Color(scheme.sub)))")
                } else {
                    Text("—").font(.system(size: 17, weight: .bold))
                        .foregroundColor(Color(g.state == .usedUp ? Palette.red : scheme.sub))
                }
            }
            .monospacedDigit()
            .padding(.top, 6)
            Text(g.caption.isEmpty ? " " : g.caption)
                .font(.system(size: 10.5)).foregroundColor(Color(scheme.sub))
                .lineLimit(1).minimumScaleFactor(0.85)
                .padding(.top, 1)
            // the other window (5-hour) under the weekly ring, small; red while it blocks the service
            if let second = g.second {
                Text(second)
                    .font(.system(size: 10, weight: g.secondUsedUp ? .semibold : .regular))
                    .foregroundColor(Color(g.secondUsedUp ? Palette.red : scheme.sub))
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .padding(.top, 3)
                if let r = g.secondReset {
                    Text(r).font(.system(size: 10)).foregroundColor(Color(scheme.sub))
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .help(g.detail ?? "")
    }
}

// B (2026-11-03): one row per service, a weekly bar and a 5-hour bar of the same shape under the name
struct LineView: View {
    let l: Design.Line
    let main: Bool                 // the weekly line: thicker bar, bolder number
    let scheme: Palette.Scheme
    var body: some View {
        HStack(spacing: 8) {
            Text(l.label).font(.system(size: 10.5, weight: main ? .bold : .semibold))
                .foregroundColor(Color(main ? scheme.fg : scheme.sub))
                .frame(width: 30, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(scheme.track))
                    if l.tone != .off && l.fraction > 0 {
                        Capsule().fill(Color(Design.color(l.tone)))
                            .frame(width: max(main ? 7 : 4, geo.size.width * CGFloat(l.fraction)))
                    }
                }
            }
            .frame(height: main ? 7 : 4)
            Text(l.value)
                .font(.system(size: main ? 12.5 : 11.5, weight: main ? .bold : .semibold)).monospacedDigit()
                .foregroundColor(Color(l.emphasis ? Palette.red : l.muted || l.tone == .stale ? scheme.sub : scheme.fg))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: L.ko ? 40 : 86, alignment: .trailing)   // "Limit reached" needs more room than "소진"
            Text(l.reset).font(.system(size: 10.5)).foregroundColor(Color(scheme.sub))
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(width: 66, alignment: .leading)
        }
        .frame(height: main ? 17 : 15)
    }
}

struct RowView: View {
    let r: Design.Row
    let scheme: Palette.Scheme
    let dark: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let img = Design.logo(r.logo, dark: dark) {
                    Image(nsImage: img).resizable().interpolation(.high).frame(width: 15, height: 15)
                        .opacity(r.staleText != nil ? 0.5 : 1)
                }
                Text(r.name).font(.system(size: 12.5, weight: .bold)).foregroundColor(Color(scheme.fg))
                Spacer(minLength: 4)
                if let t = r.staleText {
                    Circle().fill(Color(Palette.amber)).frame(width: 6, height: 6)
                    Text(t).font(.system(size: 10.5, weight: .semibold)).foregroundColor(Color(Palette.amber))
                }
            }
            .padding(.bottom, 3)
            LineView(l: r.weekly, main: true, scheme: scheme)
            if let f = r.five { LineView(l: f, main: false, scheme: scheme) }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .help(r.detail)
    }
}

// Hover that works in this menu bar app. SwiftUI's onHover only fires while the app is active, and the popover opens
// without activating the app (so it never takes focus from what you are working in): no hover effect showed at all.
// An AppKit tracking area with .activeAlways sees the pointer either way; the view lets every click through.
struct HoverArea: NSViewRepresentable {
    let onChange: (Bool) -> Void
    final class V: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var inside = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for t in trackingAreas { removeTrackingArea(t) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        }
        private func set(_ v: Bool) { if v != inside { inside = v; onChange(v) } }
        override func mouseEntered(with event: NSEvent) { set(true) }
        override func mouseExited(with event: NSEvent) { set(false) }
        // the popover closes or the view goes away while the pointer is on it: don't leave the button lit
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { set(false) } }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.onChange = onChange; return v }
    func updateNSView(_ v: V, context: Context) { v.onChange = onChange }
}
extension View {
    func hoverArea(_ onChange: @escaping (Bool) -> Void) -> some View { background(HoverArea(onChange: onChange)) }
}

// Footer text buttons (2026-11-03, "호버이펙트 간단히"): a soft rounded fill under the pointer, the text one step darker
struct FooterButton: View {
    let title: String
    let color: Color
    let bold: Bool
    var hoverColor: Color? = nil
    var fill: Color = .clear
    var forcedHover: Bool? = nil   // previews
    @ObservedObject var ui: ButtonUI
    let action: () -> Void
    var body: some View {
        let on = forcedHover ?? ui.hover
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: bold ? .bold : .regular)).foregroundColor(on ? (hoverColor ?? color) : color)
                .padding(.vertical, 5).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? fill : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverArea { h in withAnimation(.easeOut(duration: 0.12)) { ui.hover = h } }
    }
}

// The refresh arrow, drawn here instead of the SF Symbol: the symbol's circle is not at the centre of its box
// (the arrowhead sticks out), so it wobbled while it turned. This one turns around its own centre. (2026-11-03)
struct RefreshGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) * 0.34
        let a0 = -45.0, a1 = 255.0                     // degrees, y down: from 1:30 clockwise round to 11 o'clock
        var p = Path()
        p.addArc(center: c, radius: r, startAngle: .degrees(a0), endAngle: .degrees(a1), clockwise: false)
        return p
    }
}
struct RefreshHead: Shape {          // the arrowhead at the arc's end, pointing the way it turns
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY), r = min(rect.width, rect.height) * 0.34
        let t = 255.0 * Double.pi / 180
        let end = CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t))
        let d = CGPoint(x: -sin(t), y: cos(t))            // tangent, clockwise
        let n = CGPoint(x: cos(t), y: sin(t))             // outward
        let s = r * 0.62
        var p = Path()
        p.move(to: CGPoint(x: end.x + d.x * s * 0.9, y: end.y + d.y * s * 0.9))
        p.addLine(to: CGPoint(x: end.x - d.x * s * 0.35 + n.x * s * 0.75, y: end.y - d.y * s * 0.35 + n.y * s * 0.75))
        p.addLine(to: CGPoint(x: end.x - d.x * s * 0.35 - n.x * s * 0.75, y: end.y - d.y * s * 0.35 - n.y * s * 0.75))
        p.closeSubpath()
        return p
    }
}

// The refresh button: under the pointer it leans a little (40 degrees) on a soft round fill; a click turns it once all
// the way round. Both ease in and out without overshoot, so the turn starts and stops softly.
struct RefreshButton: View {
    let busy: Bool
    let scheme: Palette.Scheme
    let fill: Color
    var forcedHover: Bool? = nil   // previews
    var forcedAngle: Double? = nil
    @ObservedObject var ui: ButtonUI
    let action: () -> Void
    static let spin = Animation.timingCurve(0.45, 0, 0.2, 1, duration: 0.75)
    static let lean = Animation.easeInOut(duration: 0.28)
    var body: some View {
        let on = forcedHover ?? ui.hover
        let angle = forcedAngle ?? ((on ? 40 : 0) + ui.spins * 360)
        let ink = Color(on ? scheme.fg : scheme.sub)
        Button(action: {
            withAnimation(RefreshButton.spin) { ui.spins += 1 }
            action()
        }) {
            ZStack {
                Circle().fill(on ? fill : .clear)
                ZStack {
                    RefreshGlyph().stroke(ink, style: StrokeStyle(lineWidth: on ? 1.6 : 1.4, lineCap: .round))
                    RefreshHead().fill(ink)
                }
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(angle))
                .opacity(busy && !on ? 0.4 : 1)
            }
            .frame(width: 24, height: 24)
            .contentShape(Circle())
        }
        .buttonStyle(.plain).help(L.t("새로고침", "Refresh"))
        .hoverArea { h in withAnimation(RefreshButton.lean) { ui.hover = h } }
    }
}

struct PopoverView: View {
    @ObservedObject var model: PopoverModel
    @Environment(\.colorScheme) var colorScheme
    var forcedDark: Bool?          // previews render a fixed mode
    var rounded = false            // previews draw the popover's own corners
    var forcedHover: Int? = nil    // previews: 1 상세 보기, 2 AI 진단, 3 refresh under the pointer
    var forcedAngle: Double? = nil // previews: the refresh icon's angle mid-spin

    var body: some View {
        let dark = forcedDark ?? (colorScheme == .dark)
        let s = dark ? Palette.dark : Palette.light
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L.t("남은 한도", "Limits left")).font(.system(size: 13, weight: .bold)).foregroundColor(Color(s.fg))
                Spacer()
                if !model.header.isEmpty {
                    Text(model.header).font(.system(size: 11)).foregroundColor(Color(s.sub))
                }
            }
            .padding(.horizontal, 2).padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.rows.enumerated()), id: \.offset) { i, r in
                    if i > 0 { Rectangle().fill(Color(s.line)).frame(height: 1) }
                    RowView(r: r, scheme: s, dark: dark)
                }
            }
            .padding(.horizontal, 2)

            if let t = model.todo {
                Rectangle().fill(Color(s.line)).frame(height: 1).padding(.top, 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(L.t("지금 할 일", "To do now")).font(.system(size: 11)).foregroundColor(Color(s.sub)).padding(.bottom, 4)
                    Text("\(Text(t.name).font(.system(size: 12.5, weight: .bold))) \(Text(t.tokens).font(.system(size: 12.5)))")
                        .foregroundColor(Color(s.fg)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    Text(L.t("다음 작업은 새 대화에서", "Start the next task in a new chat")).font(.system(size: 12, weight: .semibold)).foregroundColor(Color(s.accent)).padding(.top, 2)
                }
                .padding(.horizontal, 2).padding(.top, 10)
            }

            Rectangle().fill(Color(s.line)).frame(height: 1).padding(.top, 10)
            HStack(spacing: 4) {
                let fill = Color(s.track)
                let habitOff = model.habitRunning || model.habitWait != nil
                FooterButton(title: L.t("사용량 상세 보기", "Usage details"), color: Color(s.accent), bold: true, fill: fill,
                             forcedHover: forcedHover == 1 ? true : nil, ui: model.detailsUI, action: model.onDetails)
                FooterButton(title: model.habitRunning ? L.t("진단 중…", "Checking…") : L.t("AI 진단", "AI check"), color: Color(s.sub), bold: false,
                             hoverColor: habitOff ? nil : Color(s.fg), fill: habitOff ? .clear : fill,
                             forcedHover: forcedHover == 2 ? true : nil, ui: model.habitUI, action: model.onHabit)
                    .opacity(model.habitWait != nil && !model.habitRunning ? 0.5 : 1)
                    .disabled(habitOff)
                    .help(model.habitWait ?? "")
                Spacer()
                RefreshButton(busy: model.busy, scheme: s, fill: fill,
                              forcedHover: forcedHover == 3 ? true : nil, forcedAngle: forcedAngle, ui: model.refreshUI, action: model.onRefresh)
                    .padding(.trailing, 2)
            }
            .padding(.top, 8)
            if let status = model.refreshStatus {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundColor(Color(model.refreshFailed ? Palette.amber : s.sub))
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2).padding(.top, 6)
                    .accessibilityLabel(status)
            }
        }
        .padding(.top, 14).padding(.horizontal, 14).padding(.bottom, 10)
        .frame(width: 318)
        .background(rounded ? AnyView(RoundedRectangle(cornerRadius: 14).fill(Color(s.bg))) : AnyView(Color(s.bg)))
    }
}

// `--render-preview <folder>`: PNGs of the popover for comparison with the approved mock.
enum Preview {
    // the mock's example values (Windows numbers), on Fri 2026-10-30 17:15 Seoul time
    static func mockModel(now: Date, tz: TimeZone) -> PopoverModel {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        func at(_ m: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: mi))! }
        func q(_ rem: Double, _ reset: Date, _ key: String) -> Quota { let x = Usage.ok(rem); x.resetsAt = reset; x.accountKey = key; return x }
        let codex = q(38, at(11, 4, 15, 35), "codex:a"), claude = q(86, at(10, 31, 0, 0), "claude:b"),
            grok = q(0, at(11, 2, 14, 58), "codex:a"), gem = q(100, at(11, 6, 0, 0), "ag")
        let m = PopoverModel()
        m.header = Design.header(lastCheck: now, main: [codex, claude, grok], now: now)
        m.gauges = zip([codex, claude, grok, gem], Design.logoKeys).map { Design.gauge($0, logo: $1, now: now, tz: tz) }
        claude.windows = [UsageWindow(key: "five_hour", used: 65, reset: at(10, 30, 20, 20))]
        let old = q(81, at(11, 9, 12, 0), "claude:c"); old.lastOk = now.addingTimeInterval(-6 * 3600); old.failing = true; old.stale = true
        old.error = L.t("토큰 갱신 대기: Claude Code를 한 번 열어 주세요", "Token expired: open Claude Code once")
        let agy = q(100, at(11, 6, 0, 0), "ag"); agy.windows = [UsageWindow(key: "five_hour", used: 0, reset: at(10, 30, 22, 15))]
        for x in [codex, claude, grok, gem, agy] { x.lastOk = now }
        m.rows = Design.rows(main: [codex, claude, grok], ag: [gem, agy], loaded: true, now: now, tz: tz)
            + [Design.row(old, logo: "claude", name: L.t("Claude (오래된 값 예시)", "Claude (old value example)"), ag: false, now: now, tz: tz)]
        m.todo = Design.Todo(name: L.t("\"[랜딩 페이지] 점검, 문구, 최적화\"", "\"[Landing page] review, copy, tuning\""), tokens: Design.compact(852373) + L.t(" 토큰", " tokens"))
        return m
    }

    @MainActor
    static func png(_ view: some View, _ path: String) -> Bool {
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    // a menu bar strip like the mock's: ring + "38%"
    struct BarStrip: View {
        let remaining: Double?; let logo: String?; let dark: Bool
        var body: some View {
            HStack(spacing: 5) {
                Image(nsImage: Design.menuBarRing(remaining: remaining, logoKey: logo, dark: dark))
                if let r = remaining { Text(Usage.remainingNumber(r) + "%").font(.system(size: 13, weight: .bold)) }
            }
            .foregroundColor(dark ? Color(white: 0.95) : Color(white: 0.11))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.5, opacity: 0.22)))
            .frame(width: 318, height: 26, alignment: .trailing)
            .background(dark ? Color(nsColor: Palette.hex(0x1d1c20)) : Color(nsColor: Palette.hex(0xe9e8ec)))
        }
    }

    // Offline regression captures: real view and scheduler text, no API calls or login reads.
    @MainActor
    static func renderRefresh(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let now = Date()
        var states = Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, ProviderState()) })
        states[.claude]!.lastStart = now; states[.claude]!.floorGap = 90
        states[.claude]!.requestGap = 10
        states[.agy]!.lastStart = now; states[.agy]!.floorGap = 600
        states[.agy]!.requestGap = 10
        states[.codex]!.inFlight = true; states[.grok]!.inFlight = true
        var batch = ManualRefresh(); _ = batch.begin()
        let waiting = batch.text(states: states, now: now)!
        for p in Provider.allCases { batch.finish(p, success: true, now: now) }
        let done = batch.text(states: states, now: now)!
        _ = batch.begin()
        for p in Provider.allCases { batch.finish(p, success: p != .claude, now: now) }
        let failed = batch.text(states: states, now: now)!
        for dark in [false, true] {
            for (name, text, error) in [("before", nil as String?, false), ("waiting", waiting, false), ("done", done, false), ("failed", failed, true), ("full", nil, false)] {
                let m = mockModel(now: now, tz: TimeZone(identifier: "Asia/Seoul")!)
                // "full": the mock's to-do item and old-value example row as well
                if name != "full" { m.todo = nil; m.rows = Array(m.rows.prefix(5)) }
                m.refreshStatus = text; m.refreshFailed = error
                let v = PopoverView(model: m, forcedDark: dark, rounded: true)
                    .padding(12).background(Color(nsColor: Palette.hex(0x171717)))
                let p = (dir as NSString).appendingPathComponent("refresh-\(name)-\(dark ? "dark" : "light").png")
                // NSViewRepresentable tracking areas cannot be drawn by ImageRenderer.
                let host = NSHostingView(rootView: v)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                // 2x pixels, like a Retina screen (the default cache is 1x)
                if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * 2), pixelsHigh: Int(host.bounds.height * 2),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                    bitmap.size = host.bounds.size
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try? data.write(to: URL(fileURLWithPath: p)); print(p)
                    }
                }
            }
        }
    }

    @MainActor
    static func render(to dir: String, real: (PopoverModel, Double?, String?)?) -> [String] {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tz = TimeZone(identifier: "Asia/Seoul")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 17, minute: 15))!
        var out: [String] = []
        for dark in [true, false] {
            let m = mockModel(now: now, tz: tz)
            let v = VStack(alignment: .trailing, spacing: 7) {
                BarStrip(remaining: 38, logo: "codex", dark: dark)
                PopoverView(model: m, forcedDark: dark, rounded: true)
            }
            .padding(12).background(Color(nsColor: Palette.hex(0x171717)))
            let p = (dir as NSString).appendingPathComponent(dark ? "preview-mock-dark.png" : "preview-mock-light.png")
            if png(v, p) { out.append(p) }
        }
        // footer states: normal, 상세 보기 hovered, AI 진단 hovered, refresh hovered (40 degrees), refresh mid-spin
        for dark in [false, true] {
            let m = mockModel(now: now, tz: tz); m.todo = nil
            let states: [(Int?, Double?)] = [(nil, nil), (1, nil), (2, nil), (3, nil), (3, 220)]
            let v = VStack(spacing: 6) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, st in
                    PopoverView(model: m, forcedDark: dark, rounded: true, forcedHover: st.0, forcedAngle: st.1)
                        .frame(height: 44, alignment: .bottom).clipped()
                }
            }
            .padding(12).background(Color(nsColor: Palette.hex(0x171717)))
            let p = (dir as NSString).appendingPathComponent(dark ? "preview-footer-dark.png" : "preview-footer-light.png")
            if png(v, p) { out.append(p) }
        }
        // the click's turn as frames (40 -> 400 degrees on the same curve), for a gif check of the motion
        do {
            let fdir = (dir as NSString).appendingPathComponent("spin")
            try? FileManager.default.createDirectory(atPath: fdir, withIntermediateDirectories: true)
            func bez(_ t: Double) -> Double {   // cubic-bezier(0.45, 0, 0.2, 1): solve x(u) = t, return y(u)
                var lo = 0.0, hi = 1.0
                for _ in 0..<40 {
                    let u = (lo + hi) / 2, x = 3 * (1 - u) * (1 - u) * u * 0.45 + 3 * (1 - u) * u * u * 0.2 + u * u * u
                    if x < t { lo = u } else { hi = u }
                }
                let u = (lo + hi) / 2
                return 3 * (1 - u) * u * u * 1 + u * u * u
            }
            let n = 45   // 0.75 s at 60 fps
            var k = 0
            for i in 0...(n + 15) {
                let t = min(1, Double(i) / Double(n))
                let v = RefreshButton(busy: false, scheme: Palette.light, fill: Color(Palette.light.track), forcedHover: true,
                                      forcedAngle: 40 + 360 * bez(t), ui: ButtonUI(), action: {})
                    .padding(8).background(Color(nsColor: Palette.light.bg))
                if png(v, (fdir as NSString).appendingPathComponent(String(format: "f%03d.png", k))) { k += 1 }
            }
        }
        if let (m, rem, logo) = real {
            let dark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let v = VStack(alignment: .trailing, spacing: 7) {
                BarStrip(remaining: rem, logo: logo, dark: dark)
                PopoverView(model: m, forcedDark: dark, rounded: true)
            }
            .padding(12).background(Color(nsColor: Palette.hex(0x171717)))
            let p = (dir as NSString).appendingPathComponent("preview-real.png")
            if png(v, p) { out.append(p) }
        }
        return out
    }
}
