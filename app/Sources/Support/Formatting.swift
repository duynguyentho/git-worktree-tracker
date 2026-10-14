import AppKit
import SwiftUI

func memText(_ kb: Int) -> String {
    kb >= 1_048_576 ? String(format: "%.1f GB", Double(kb) / 1_048_576) : "\(kb / 1024) MB"
}

func cpuText(_ c: Double) -> String { c < 10 ? String(format: "%.1f%%", c) : String(format: "%.0f%%", c) }

func relative(_ ts: Int?) -> String {
    guard let ts else { return "—" }
    let s = Date().timeIntervalSince1970 - Double(ts)
    if s < 60 { return "just now" }
    if s < 3600 { return "\(Int(s / 60))m ago" }
    if s < 86400 { return "\(Int(s / 3600))h ago" }
    return "\(Int(s / 86400))d ago"
}

func sizeText(_ nm: Artifacts) -> String {
    switch nm.kind {
    case "link": return "linked"
    case "dir": return nm.kb.map { String(format: "%.1f GB", Double($0) / 1e6) } ?? "…"
    default: return "—"
    }
}

func shortSession(_ s: ClaudeSession) -> String {
    let n = s.name ?? "claude"
    return n.split(separator: "-").last.map(String.init) ?? n
}

func gbText(_ gb: Double) -> String { String(format: "%.1f GB", gb) }

func plural(_ n: Int, _ word: String) -> String {
    n == 1 ? "1 \(word)" : "\(n) \(word)\(word.hasSuffix("s") ? "es" : "s")"
}

func rateText(_ bps: Double) -> String {
    if bps >= 1_048_576 { return String(format: "%.1fM/s", bps / 1_048_576) }
    if bps >= 1024 { return String(format: "%.0fK/s", bps / 1024) }
    return String(format: "%.0fB/s", bps)
}

func durationText(_ seconds: Int) -> String {
    let h = seconds / 3600, m = seconds % 3600 / 60
    return h > 0 ? (m > 0 ? "\(h)h \(m)m" : "\(h)h") : "\(m)m"
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

func tildePath(_ p: String) -> String { p.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
