import Foundation

// UI language, as on Windows (UsageGauge.cs `L`): follows the macOS language (Korean when the first preferred
// language is Korean, anything else English). The right-click menu can force one; the choice is kept in lang.txt
// (auto | ko | en) next to menubar.log. USAGEGAUGE_LANG=ko|en overrides it for one run (previews, tests) without
// writing the file.
enum L {
    static var mode = "auto"
    static var ko = true
    static var file: String { (Paths.appHome as NSString).appendingPathComponent("lang.txt") }

    static func systemIsKorean() -> Bool { (Locale.preferredLanguages.first ?? "").lowercased().hasPrefix("ko") }

    static func load() {
        if let e = ProcessInfo.processInfo.environment["USAGEGAUGE_LANG"]?.lowercased(), e == "ko" || e == "en" {
            mode = e; apply(); return
        }
        let saved = (try? String(contentsOfFile: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        mode = saved == "ko" || saved == "en" ? saved! : "auto"
        apply()
    }
    static func set(_ m: String) {
        mode = m == "ko" || m == "en" ? m : "auto"
        try? FileManager.default.createDirectory(atPath: Paths.appHome, withIntermediateDirectories: true)
        try? mode.write(toFile: file, atomically: true, encoding: .utf8)
        apply()
    }
    static func apply() { ko = mode == "ko" || (mode == "auto" && systemIsKorean()) }

    static func t(_ ko: String, _ en: String) -> String { L.ko ? ko : en }
}
