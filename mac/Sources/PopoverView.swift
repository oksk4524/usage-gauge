import AppKit
import SwiftUI

// The popover of the approved design: "남은 한도" + four ring gauges, "지금 할 일" (only when there is one),
// and a footer of text buttons. Colors follow the system light/dark mode.

final class PopoverModel: ObservableObject {
    @Published var header = ""
    @Published var gauges: [Design.Gauge] = []
    @Published var todo: Design.Todo?
    @Published var busy = false
    @Published var habitRunning = false
    var onDetails: () -> Void = {}
    var onHabit: () -> Void = {}
    var onRefresh: () -> Void = {}
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
        }
        .frame(maxWidth: .infinity)
        .help(g.detail ?? "")
    }
}

struct FooterButton: View {
    let title: String
    let color: Color
    let bold: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: bold ? .bold : .regular)).foregroundColor(color)
                .padding(.vertical, 5).padding(.horizontal, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PopoverView: View {
    @ObservedObject var model: PopoverModel
    @Environment(\.colorScheme) var colorScheme
    var forcedDark: Bool?          // previews render a fixed mode
    var rounded = false            // previews draw the popover's own corners

    var body: some View {
        let dark = forcedDark ?? (colorScheme == .dark)
        let s = dark ? Palette.dark : Palette.light
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("남은 한도").font(.system(size: 13, weight: .bold)).foregroundColor(Color(s.fg))
                Spacer()
                if !model.header.isEmpty {
                    Text(model.header).font(.system(size: 11)).foregroundColor(Color(s.sub))
                }
            }
            .padding(.horizontal, 2).padding(.bottom, 12)

            HStack(alignment: .top, spacing: 4) {
                ForEach(Array(model.gauges.enumerated()), id: \.offset) { _, g in GaugeColumn(g: g, scheme: s, dark: dark) }
            }

            if let t = model.todo {
                Rectangle().fill(Color(s.line)).frame(height: 1).padding(.top, 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text("지금 할 일").font(.system(size: 11)).foregroundColor(Color(s.sub)).padding(.bottom, 4)
                    Text("\(Text(t.name).font(.system(size: 12.5, weight: .bold))) \(Text(t.tokens).font(.system(size: 12.5)))")
                        .foregroundColor(Color(s.fg)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    Text("다음 작업은 새 대화에서").font(.system(size: 12, weight: .semibold)).foregroundColor(Color(s.accent)).padding(.top, 2)
                }
                .padding(.horizontal, 2).padding(.top, 10)
            }

            Rectangle().fill(Color(s.line)).frame(height: 1).padding(.top, 10)
            HStack(spacing: 4) {
                FooterButton(title: "사용량 상세 보기", color: Color(s.accent), bold: true, action: model.onDetails)
                FooterButton(title: model.habitRunning ? "진단 중…" : "AI 진단", color: Color(s.sub), bold: false, action: model.onHabit)
                    .disabled(model.habitRunning)
                Spacer()
                Button(action: model.onRefresh) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium)).foregroundColor(Color(s.sub))
                        .opacity(model.busy ? 0.4 : 1)
                        .padding(.vertical, 5).padding(.horizontal, 8).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(model.busy).help("새로고침")
            }
            .padding(.top, 8)
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
        m.todo = Design.Todo(name: "\"[유령마작] 점검·스토리·최적화\"", tokens: Design.compact(852373) + " 토큰")
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
