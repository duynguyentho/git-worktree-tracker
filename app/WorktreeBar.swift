import AppKit
import Charts
import Darwin
import SwiftUI

// MARK: - Model (shape of `scripts/wt.py list --json`)

struct Payload: Decodable {
    let generated_at: Int
    let disk: Disk
    let totals: Totals
    var worktrees: [Worktree]
    let config: AppConfig?
    let bases: [String]?
    let configured: Bool?
}

/// Local, uncommitted settings from ~/.config/git-worktree-tracker/config.json (passed through by wt.py).
struct AppConfig: Decodable {
    let jira_url: String?
    let repos: [String: RepoConfig]?
}

struct RepoConfig: Decodable { let label: String?; let hue: Double? }

struct Disk: Decodable { let free_gb: Double; let total_gb: Double }

struct Totals: Decodable {
    let count: Int
    let artifacts_gb: Double
    let reclaimable_gb: Double
    let sizes_complete: Bool
}

struct Worktree: Decodable, Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let repo: String
    let branch: String?
    let ticket: String?
    let head: String?
    let state: String
    let reasons: [String]
    let remove_blockers: [String]
    let removable: Bool
    let force_blockers: [String]?
    let git: GitInfo
    let pr: PullRequest?
    let run: RunInfo?
    let artifacts: Artifacts
    let ecosystems: [String]?
    var procs: [Proc]
    let pr_status: PRStatus?
    let base_sync: BaseSync?
    var sessions: [ClaudeSession]?
    var warp: WarpTarget?

    var attention: Bool {
        ["CHECKS_FAILED", "CONFLICTING", "CHANGES_REQUESTED"].contains(pr_status?.state ?? "")
    }
    var rssKB: Int { procs.reduce(0) { $0 + ($1.rss_kb ?? 0) } }
    var cpu: Double { procs.reduce(0) { $0 + ($1.cpu ?? 0) } }
    var usage: String { "\(memText(rssKB)) · \(cpuText(cpu))" }
    var dirty: Int { (git.modified ?? 0) + (git.untracked ?? 0) }
    var title: String { ticket ?? name }
    var branchLabel: String { branch ?? "detached @ \(head.map { String($0.prefix(8)) } ?? "?")" }
    var gb: Double { Double(artifacts.kb ?? 0) / 1e6 }
    var missingPath: Bool { state == "missing" }
    var forceRemovable: Bool { !removable && (force_blockers ?? ["unknown"]).isEmpty }
    var forceLoss: String { remove_blockers.joined(separator: " · ") }
}

struct GitInfo: Decodable {
    let modified: Int?
    let untracked: Int?
    let ahead: Int?
    let behind: Int?
    let upstream: String?
    let unpushed: Int?
    let activity_ts: Int?
    let last_commit: Commit?
    let files: [DirtyFile]?
}

struct DirtyFile: Decodable, Hashable { let s: String; let p: String }

struct PRCheck: Decodable, Hashable { let name: String; let bucket: String; let link: String? }

struct PRStatus: Decodable {
    let state: String
    let mergeable: String?
    let review_decision: String?
    let reviews: Int?
    let checks: [PRCheck]?
    let failed_checks: [String]?
    let next: String?
    let at: Int?
    let error: String?
}

struct BaseSync: Decodable { let base: String; let behind: Int; let ahead: Int; let fetched_ts: Int? }

struct ClaudeSession: Decodable, Hashable {
    let pid: Int
    let name: String?
    let status: String?
    let session_id: String?
    let warp: String?
    let last_ts: Int?
}

struct WarpTarget: Decodable, Hashable { let uuid: String; let source: String; let label: String? }

struct SessionTargets: Decodable { let sessions: [ClaudeSession]; let warp: WarpTarget? }
struct ProcsPayload: Decodable { let procs: [String: [Proc]]; let targets: [String: SessionTargets] }

/// What a PR needs from you, most urgent first — pr_watch.py's states.
func prStatusTone(_ s: PRStatus) -> (String, Tone, String) {
    switch s.state {
    case "CHECKS_FAILED": return ("checks failed", Tone(fg: T.danger, bg: T.dangerSoft), "xmark.octagon.fill")
    case "CONFLICTING": return ("conflict", Tone(fg: T.danger, bg: T.dangerSoft), "arrow.triangle.merge")
    case "CHANGES_REQUESTED": return ("changes", Tone(fg: T.danger, bg: T.dangerSoft), "exclamationmark.bubble.fill")
    case "CHECKS_PENDING": return ("checks running", Tone(fg: T.amber, bg: T.amberSoft), "clock.fill")
    case "APPROVED": return ("approved", Tone(fg: T.green, bg: T.greenSoft), "checkmark.seal.fill")
    case "WAITING_REVIEW": return ("in review", Tone(fg: T.blue, bg: T.blueSoft), "eye.fill")
    case "DRAFT": return ("draft", Tone(fg: T.muted, bg: T.neutralSoft), "pencil")
    case "MERGED": return ("merged", Tone(fg: T.purple, bg: T.purpleSoft), "arrow.triangle.merge")
    case "ERROR": return ("status error", Tone(fg: T.muted, bg: T.neutralSoft), "questionmark")
    default: return (s.state.lowercased(), Tone(fg: T.muted, bg: T.neutralSoft), "circle")
    }
}
struct Commit: Decodable { let sha: String; let ts: Int; let subject: String }

struct PullRequest: Decodable {
    let number: Int
    let state: String
    let url: String
    let title: String?
    let reviewDecision: String?
    let baseRefName: String?
}

struct RunInfo: Decodable { let stage: String?; let status: String?; let next_action: String?; let updated: String? }
/// Git-ignored dependency/build dirs at the worktree root (node_modules, .venv, target, …).
struct Artifacts: Decodable {
    let kind: String
    let kb: Int?
    let items: [ArtifactItem]?

    var label: String {
        let names = (items ?? []).filter { $0.kind == "dir" }.map(\.name)
        return names.count == 1 ? names[0] : "Deps & builds"
    }
    var breakdown: String {
        (items ?? []).map { "\($0.name)  \($0.kind == "link" ? "linked" : $0.kb.map { String(format: "%.1f GB", Double($0) / 1e6) } ?? "…")" }
            .joined(separator: "\n")
    }
}

struct ArtifactItem: Decodable, Hashable { let name: String; let kind: String; let kb: Int? }
struct Proc: Decodable {
    let pid: Int
    let name: String?
    let cmd: String?
    let ports: [String]
    let etime: String?
    let rss_kb: Int?
    let cpu: Double?
    let child: Bool?
}

func memText(_ kb: Int) -> String {
    kb >= 1_048_576 ? String(format: "%.1f GB", Double(kb) / 1_048_576) : "\(kb / 1024) MB"
}

func cpuText(_ c: Double) -> String { c < 10 ? String(format: "%.1f%%", c) : String(format: "%.0f%%", c) }

let stateOrder = ["active", "review", "idle", "stale", "merged", "closed", "missing"]
let prunable: Set<String> = ["merged", "closed", "missing"]

/// Editors found on this Mac (id, label, bundle id), in preference order.
let editors: [(id: String, label: String, app: String)] = {
    let known: [(String, String, [String])] = [
        ("code", "VS Code", ["com.microsoft.VSCode"]),
        ("cursor", "Cursor", ["com.todesktop.230313mzl4w4u92"]),
        ("webstorm", "WebStorm", ["com.jetbrains.WebStorm"]),
        ("goland", "GoLand", ["com.jetbrains.goland"]),
        ("pycharm", "PyCharm", ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce"]),
        ("idea", "IntelliJ IDEA", ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]),
        ("rider", "Rider", ["com.jetbrains.rider"]),
        ("zed", "Zed", ["dev.zed.Zed"]),
        ("sublime", "Sublime Text", ["com.sublimetext.4", "com.sublimetext.3"]),
        ("xcode", "Xcode", ["com.apple.dt.Xcode"]),
    ]
    let found = known.compactMap { id, label, ids -> (id: String, label: String, app: String)? in
        ids.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }.map { (id, label, $0) }
    }
    return found.isEmpty ? [("finder", "Finder", "com.apple.finder")] : found
}()

let hasWarp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.warp.Warp-Stable") != nil

// MARK: - Theme (tokens from the "Worktrees for macOS" design canvas, app-tokens)

func oklch(_ L: Double, _ C: Double, _ h: Double, _ alpha: Double = 1) -> NSColor {
    let a = C * cos(h * .pi / 180), b = C * sin(h * .pi / 180)
    let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
    let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
    let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
    func gamma(_ x: Double) -> CGFloat {
        let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        return CGFloat(min(max(v, 0), 1))
    }
    return NSColor(srgbRed: gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                   green: gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                   blue: gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
                   alpha: CGFloat(alpha))
}

func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    })
}

enum T {
    static let bg = dyn(oklch(0.985, 0.003, 250), oklch(0.16, 0.008, 250))
    static let panel = dyn(oklch(1, 0, 0), oklch(0.18, 0.008, 250))
    static let section = dyn(oklch(0.975, 0.003, 250), oklch(0.21, 0.009, 250))
    static let control = dyn(oklch(1, 0, 0), oklch(0.23, 0.010, 250))
    static let controlHover = dyn(oklch(0.965, 0.004, 250), oklch(0.28, 0.010, 250))
    static let sidebar = dyn(oklch(0.965, 0.004, 250, 0.9), oklch(0.22, 0.010, 250, 0.72))
    static let sheet = dyn(oklch(1, 0, 0), oklch(0.20, 0.009, 250))
    static let well = dyn(oklch(0.94, 0.005, 250), oklch(0.28, 0.010, 250))
    static let hair = dyn(oklch(0.18, 0.01, 250, 0.09), oklch(0.97, 0.003, 250, 0.07))
    static let hairSoft = dyn(oklch(0.18, 0.01, 250, 0.06), oklch(0.97, 0.003, 250, 0.05))
    static let hover = dyn(oklch(0.18, 0.01, 250, 0.04), oklch(0.97, 0.003, 250, 0.04))
    static let navOn = dyn(oklch(0.18, 0.01, 250, 0.07), oklch(0.97, 0.003, 250, 0.10))
    static let navHover = dyn(oklch(0.18, 0.01, 250, 0.04), oklch(0.97, 0.003, 250, 0.06))

    static let fg = dyn(oklch(0.18, 0.01, 250), oklch(0.97, 0.003, 250))
    static let muted = dyn(oklch(0.45, 0.01, 250), oklch(0.74, 0.006, 250))
    static let subtle = dyn(oklch(0.56, 0.008, 250), oklch(0.58, 0.008, 250))
    static let faint = dyn(oklch(0.78, 0.005, 250), oklch(0.42, 0.008, 250))

    static let accent = Color(nsColor: oklch(0.55, 0.18, 250))
    static let accentText = dyn(oklch(0.50, 0.18, 250), oklch(0.72, 0.14, 250))
    static let accentSoft = dyn(oklch(0.55, 0.18, 250, 0.10), oklch(0.65, 0.18, 250, 0.18))
    static let accentBorder = dyn(oklch(0.55, 0.18, 250, 0.40), oklch(0.65, 0.18, 250, 0.45))
    static let onAccent = Color(nsColor: oklch(0.99, 0, 0))

    static let amber = dyn(oklch(0.60, 0.14, 65), oklch(0.80, 0.14, 75))
    static let amberSoft = dyn(oklch(0.80, 0.14, 75, 0.18), oklch(0.80, 0.14, 75, 0.16))
    static let amberRow = dyn(oklch(0.80, 0.14, 75, 0.10), oklch(0.80, 0.14, 75, 0.07))
    static let green = dyn(oklch(0.52, 0.15, 150), oklch(0.80, 0.17, 150))
    static let greenSoft = Color(nsColor: oklch(0.72, 0.17, 150, 0.16))
    static let danger = dyn(oklch(0.52, 0.20, 25), oklch(0.78, 0.14, 25))
    static let dangerSoft = Color(nsColor: oklch(0.65, 0.20, 25, 0.12))
    static let dangerBorder = Color(nsColor: oklch(0.65, 0.20, 25, 0.35))
    static let purple = dyn(oklch(0.50, 0.16, 300), oklch(0.80, 0.12, 300))
    static let purpleSoft = Color(nsColor: oklch(0.68, 0.16, 300, 0.18))
    static let blue = dyn(oklch(0.50, 0.16, 250), oklch(0.80, 0.10, 250))
    static let blueSoft = Color(nsColor: oklch(0.65, 0.18, 250, 0.16))
    static let neutralSoft = dyn(oklch(0.18, 0.01, 250, 0.06), oklch(0.97, 0.003, 250, 0.08))

    static let diskOther = dyn(oklch(0.72, 0.008, 250), oklch(0.58, 0.008, 250))
    static let diskNM = Color(nsColor: oklch(0.65, 0.16, 250))
    static let diskReclaim = Color(nsColor: oklch(0.80, 0.14, 75))
}

enum F {
    static let hasInter = NSFont(name: "Inter", size: 12) != nil
    static let hasJB = NSFont(name: "JetBrains Mono", size: 12) != nil

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        hasInter ? .custom("Inter", size: size).weight(weight) : .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        hasJB ? .custom("JetBrains Mono", size: size).weight(weight) : .system(size: size, weight: weight, design: .monospaced)
    }
}

struct Tone { let fg: Color; let bg: Color }

struct StateStyle {
    let title: String
    let symbol: String
    let tone: Tone

    static func of(_ s: String) -> StateStyle {
        switch s {
        case "active": return .init(title: "Active", symbol: "bolt.fill", tone: Tone(fg: T.green, bg: T.greenSoft))
        case "review": return .init(title: "In review", symbol: "eye.fill", tone: Tone(fg: T.blue, bg: T.blueSoft))
        case "idle": return .init(title: "Idle", symbol: "moon.fill", tone: Tone(fg: T.muted, bg: T.neutralSoft))
        case "stale": return .init(title: "Stale", symbol: "hourglass", tone: Tone(fg: T.amber, bg: T.amberSoft))
        case "merged": return .init(title: "Merged", symbol: "arrow.triangle.merge", tone: Tone(fg: T.purple, bg: T.purpleSoft))
        case "closed": return .init(title: "Closed", symbol: "xmark", tone: Tone(fg: T.muted, bg: T.neutralSoft))
        default: return .init(title: "Missing", symbol: "questionmark.folder", tone: Tone(fg: T.danger, bg: T.dangerSoft))
        }
    }
}

struct RepoStyle {
    let short: String
    let hue: Double

    var tone: Tone { Tone(fg: dyn(oklch(0.48, 0.13, hue), oklch(0.80, 0.10, hue)), bg: Color(nsColor: oklch(0.65, 0.16, hue, 0.16))) }
    var dot: Color { Color(nsColor: oklch(0.65, 0.16, hue)) }

    static var config: [String: RepoConfig] = [:]

    /// Label + hue from the local config, else the repo name and a hue derived from it.
    static func of(_ repo: String) -> RepoStyle {
        let c = config[repo]
        let hashed = Double(repo.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 })
        return .init(short: c?.label ?? repo, hue: c?.hue ?? hashed)
    }
}

func prTone(_ pr: PullRequest) -> (String, Tone) {
    switch pr.state {
    case "OPEN":
        switch pr.reviewDecision {
        case "APPROVED": return ("approved", Tone(fg: T.green, bg: T.greenSoft))
        case "CHANGES_REQUESTED": return ("changes requested", Tone(fg: T.danger, bg: T.dangerSoft))
        default: return ("open", Tone(fg: T.blue, bg: T.blueSoft))
        }
    case "MERGED": return ("merged", Tone(fg: T.purple, bg: T.purpleSoft))
    default: return ("closed", Tone(fg: T.muted, bg: T.neutralSoft))
    }
}

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

// MARK: - Live sampler (libproc — what Activity Monitor reads; ~1ms for every process on the machine)

struct LiveSample { let t: Date; let cpu: Double; let memKB: Int }

final class LiveSampler {
    private var prev: [pid_t: (cpuTicks: UInt64, at: Date)] = [:]
    private let nsPerTick: Double

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        nsPerTick = Double(tb.numer) / Double(tb.denom)
    }

    /// root path → processes whose cwd is inside it, plus all their descendants.
    /// cpu = instantaneous % since the previous sample (100 = one full core); rss_kb = phys footprint.
    func sample(roots: [String], enrich: [Int: Proc]) -> [String: [Proc]] {
        let now = Date()
        let sortedRoots = roots.sorted { $0.count > $1.count }
        var bsd: [pid_t: proc_bsdinfo] = [:]
        var children: [pid_t: [pid_t]] = [:]
        var rootOf: [pid_t: String] = [:]
        for pid in Self.allPids() {
            guard let b = Self.bsdInfo(pid) else { continue }
            bsd[pid] = b
            children[pid_t(b.pbi_ppid), default: []].append(pid)
            if let cwd = Self.cwd(pid), let root = sortedRoots.first(where: { cwd == $0 || cwd.hasPrefix($0 + "/") }) {
                rootOf[pid] = root
            }
        }
        var isChild: [pid_t: Bool] = rootOf.mapValues { _ in false }
        var stack = Array(rootOf.keys)
        while let parent = stack.popLast() {
            for c in children[parent] ?? [] where rootOf[c] == nil {
                rootOf[c] = rootOf[parent]
                isChild[c] = true
                stack.append(c)
            }
        }

        var next: [pid_t: (UInt64, Date)] = [:]
        var out: [String: [Proc]] = [:]
        for (pid, root) in rootOf {
            guard let (ticks, footprint) = Self.usage(pid), let b = bsd[pid] else { continue }
            next[pid] = (ticks, now)
            var cpu = enrich[Int(pid)]?.cpu ?? 0
            if let p = prev[pid], ticks >= p.cpuTicks {
                let wall = now.timeIntervalSince(p.at)
                if wall > 0.2 { cpu = Double(ticks - p.cpuTicks) * nsPerTick / 1e9 / wall * 100 }
            }
            let name = Self.string(b.pbi_name).isEmpty ? Self.string(b.pbi_comm) : Self.string(b.pbi_name)
            let extra = enrich[Int(pid)]
            out[root, default: []].append(Proc(
                pid: Int(pid), name: name, cmd: extra?.cmd ?? name, ports: extra?.ports ?? [],
                etime: Self.elapsed(Int(now.timeIntervalSince1970) - Int(b.pbi_start_tvsec)),
                rss_kb: Int(footprint / 1024), cpu: cpu, child: isChild[pid] ?? false))
        }
        prev = next
        return out.mapValues { $0.sorted { ($0.rss_kb ?? 0) > ($1.rss_kb ?? 0) } }
    }

    static func allPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        return buf.prefix(Int(max(got, 0))).filter { $0 > 0 }
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return string(info.pvi_cdir.vip_path)
    }

    static func usage(_ pid: pid_t) -> (UInt64, UInt64)? {
        var ru = rusage_info_v2()
        let r = withUnsafeMutablePointer(to: &ru) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return r == 0 ? (ru.ri_user_time + ru.ri_system_time, ru.ri_phys_footprint) : nil
    }

    static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static func elapsed(_ s: Int) -> String {
        let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60, sec = s % 60
        if d > 0 { return String(format: "%d-%02d:%02d:%02d", d, h, m, sec) }
        if h > 0 { return String(format: "%02d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}

// MARK: - Live charts

struct Sparkline: View {
    let values: [Double]
    let color: Color
    var ceiling: Double? = nil

    var body: some View {
        GeometryReader { g in
            let top = max(ceiling ?? (values.max() ?? 1), 0.0001)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: g.size.width * CGFloat(i) / CGFloat(max(Store.historyLength - 1, 1))
                           + g.size.width * CGFloat(Store.historyLength - values.count) / CGFloat(max(Store.historyLength - 1, 1)),
                        y: g.size.height * (1 - CGFloat(min(v / top, 1))))
            }
            ZStack {
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: CGPoint(x: f.x, y: g.size.height))
                    pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height))
                }
                .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: f)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
    }
}

struct LiveChart: View {
    let title: String
    let samples: [LiveSample]
    let value: (LiveSample) -> Double
    let format: (Double) -> String
    let color: Color

    var body: some View {
        let now = samples.last.map(value) ?? 0
        let peak = samples.map(value).max() ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(F.ui(11.5, .medium)).foregroundStyle(T.subtle)
                Spacer()
                Text("peak \(format(peak))").font(F.ui(11)).monospacedDigit().foregroundStyle(T.subtle)
            }
            Text(format(now)).font(F.ui(20, .bold)).monospacedDigit().foregroundStyle(color)
                .contentTransition(.numericText())
            Chart(samples, id: \.t) { s in
                AreaMark(x: .value("t", s.t), y: .value(title, value(s)))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.30), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", s.t), y: .value(title, value(s)))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.monotone)
            }
            .chartXScale(domain: Date().addingTimeInterval(-Double(Store.historyLength))...Date())
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(T.hairSoft)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(format(d)).font(F.ui(10)).foregroundStyle(T.subtle) } }
                }
            }
            .frame(height: 90)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(dyn(oklch(1, 0, 0), oklch(0.18, 0.008, 250))))
    }
}

struct LiveDot: View {
    var compact = false
    @State private var on = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(T.green).frame(width: 7, height: 7)
                .opacity(on ? 1 : 0.35)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            if !compact { Text("LIVE · 1s").font(F.ui(10.5, .bold)).tracking(0.4).foregroundStyle(T.green) }
        }
        .onAppear { on = true }
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var data: Payload?
    @Published var loading = false
    @Published var busy: String?
    @Published var error: String?

    let script: String
    private var timer: Timer?
    private var procTimer: Timer?
    private var liveTimer: Timer?
    private var polling = false
    private let sampler = LiveSampler()
    private var enrich: [Int: Proc] = [:]
    @Published var history: [String: [LiveSample]] = [:]
    static let historyLength = 120

    init() {
        // A dev build points at the checkout (live edits); a release build runs the bundled copy.
        let dev = Bundle.main.object(forInfoDictionaryKey: "WTScriptPath") as? String
        script = dev.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            ?? Bundle.main.path(forResource: "wt", ofType: "py") ?? ""
        refresh(withSizes: true)
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(withSizes: true) }
        }
        procTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollProcesses() }
        }
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleLive() }
        }
    }

    var running: [Worktree] { worktrees.filter { !$0.procs.isEmpty }.sorted { $0.rssKB > $1.rssKB } }

    /// Live RAM/CPU: `wt.py procs <paths>` (~0.3s) every 5s while the app is frontmost.
    private func synthesiseHistory() {
        guard history.isEmpty, let d = data else { return }
        let now = Date()
        for w in d.worktrees where !w.procs.isEmpty {
            let seed = Double(w.path.count)
            history[w.path] = (0..<Self.historyLength).map { i in
                let t = Double(i)
                let cpu = max(0, w.cpu * (0.55 + 0.45 * sin(t / 7 + seed)) + 25 * sin(t / 2.3) * sin(t / 11))
                let mem = Double(w.rssKB) * (0.82 + 0.18 * Double(i) / Double(Self.historyLength))
                return LiveSample(t: now.addingTimeInterval(Double(i - Self.historyLength)), cpu: cpu, memKB: Int(mem))
            }
        }
    }

    var visible: Bool { NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) } }

    /// Command lines + listening ports change rarely and need lsof — refreshed from wt.py every 15s.
    /// Membership, CPU and memory come from the 1s libproc sampler below.
    func pollProcesses() {
        guard Self.fixture == nil, visible, !polling, busy == nil, let paths = data?.worktrees.map(\.path), !paths.isEmpty else { return }
        polling = true
        Task {
            let (code, out, _) = await Shell.run("/usr/bin/python3", [script, "procs", "--with-sessions"] + paths)
            polling = false
            guard code == 0, let raw = out.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(ProcsPayload.self, from: raw) else { return }
            enrich = Dictionary(payload.procs.values.flatMap { $0 }.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            guard var d = data else { return }
            for i in d.worktrees.indices {
                let t = payload.targets[d.worktrees[i].path]
                d.worktrees[i].sessions = t?.sessions ?? []
                d.worktrees[i].warp = t?.warp
            }
            data = d
        }
    }

    func sampleLive() {
        if Self.fixture != nil {
            synthesiseHistory()
            return
        }
        guard visible, var d = data, !d.worktrees.isEmpty else { return }
        let byRoot = sampler.sample(roots: d.worktrees.filter { !$0.missingPath }.map(\.path), enrich: enrich)
        let now = Date()
        var hist = history
        for i in d.worktrees.indices {
            let path = d.worktrees[i].path
            let procs = byRoot[path] ?? []
            d.worktrees[i].procs = procs
            if procs.isEmpty && hist[path] == nil { continue }
            var h = hist[path] ?? []
            h.append(LiveSample(t: now, cpu: procs.reduce(0) { $0 + ($1.cpu ?? 0) }, memKB: procs.reduce(0) { $0 + ($1.rss_kb ?? 0) }))
            if h.count > Self.historyLength { h.removeFirst(h.count - Self.historyLength) }
            hist[path] = h.allSatisfy { $0.memKB == 0 } ? nil : h
        }
        history = hist
        data = d
    }

    var worktrees: [Worktree] { data?.worktrees ?? [] }
    var cleanupCandidates: [Worktree] {
        worktrees.filter { prunable.contains($0.state) || ["MERGED", "CLOSED"].contains($0.pr?.state ?? "") }
    }
    var pruneCandidates: [Worktree] { cleanupCandidates.filter(\.removable) }
    func count(_ state: String) -> Int { worktrees.filter { $0.state == state }.count }

    func refresh(withSizes: Bool = false, force: Bool = false) {
        guard !loading else { return }
        loading = true
        Task {
            if data == nil { await load(["list", "--json", "--offline"]) }
            await load(["list", "--json"] + (force ? ["--refresh"] : []))
            if withSizes, data?.totals.sizes_complete == false {
                await load(["list", "--json", "--sizes"])
            }
            loading = false
        }
    }

    /// Demo mode for screenshots: `WT_FIXTURE=demo.json` renders a saved payload — no scanning,
    /// no gh, no process sampling (CPU history is synthesised for worktrees with processes).
    static let fixture = ProcessInfo.processInfo.environment["WT_FIXTURE"]

    private func load(_ args: [String]) async {
        if let f = Self.fixture {
            if let raw = FileManager.default.contents(atPath: f) {
                do {
                    data = try JSONDecoder().decode(Payload.self, from: raw)
                    RepoStyle.config = data?.config?.repos ?? [:]
                } catch { self.error = "fixture: \(error)" }
            }
            return
        }
        let (code, out, err) = await Shell.run("/usr/bin/python3", [script] + args)
        guard code == 0, let raw = out.data(using: .utf8) else {
            error = err.isEmpty ? "wt.py exited \(code)" : String(err.suffix(400))
            return
        }
        do {
            data = try JSONDecoder().decode(Payload.self, from: raw)
            RepoStyle.config = data?.config?.repos ?? [:]
            error = nil
        } catch {
            self.error = "decode: \(error)"
        }
    }

    func action(_ label: String, _ args: [String], hiding paths: Set<String> = [], report: Bool = false) {
        busy = label
        if !paths.isEmpty { data?.worktrees.removeAll { paths.contains($0.path) } }
        Task {
            let (code, out, err) = await Shell.run("/usr/bin/python3", [script] + args)
            busy = nil
            let backups = out.split(separator: "\n").filter { $0.contains("· backup ") }
                .map { $0.replacingOccurrences(of: "removed ", with: "• ").replacingOccurrences(of: "  · backup ", with: "\n   ") }
            if code != 0 {
                Alerts.info("\(label.replacingOccurrences(of: "…", with: "")) — some items need attention",
                            ((err.isEmpty ? out : err).trimmingCharacters(in: .whitespacesAndNewlines))
                            + (backups.isEmpty ? "" : "\n\nBackups:\n" + backups.joined(separator: "\n")))
            } else if report, !backups.isEmpty {
                Alerts.info("Force removed — local changes backed up",
                            backups.joined(separator: "\n") + "\n\nEach folder has changes.patch, untracked/ and a README with restore steps.")
            }
            loading = false
            refresh()
        }
    }

    static var editor: (id: String, label: String, app: String) {
        let id = UserDefaults.standard.string(forKey: "editor") ?? editors[0].id
        return editors.first { $0.id == id } ?? editors[0]
    }

    func openEditor(_ w: Worktree) { Shell.open(["-b", Self.editor.app, w.path]) }
    /// Jumps to the Warp pane already working on this worktree (the Claude session on it, a process
    /// running in it, or a shell cd'ed into it) via Warp's own `warp://session/<uuid>`; else a new tab there.
    func openTerminal(_ w: Worktree) {
        guard hasWarp else {
            Shell.open(["-a", "Terminal", w.path])
            return
        }
        if let u = w.warp?.uuid {
            Shell.open(["warp://session/\(u)"])
        } else {
            openNewWarpTab(w)
        }
    }

    func openNewWarpTab(_ w: Worktree) {
        let q = w.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? w.path
        Shell.open(["warp://action/new_tab?path=\(q)"])
    }

    func jump(_ s: ClaudeSession) {
        if let u = s.warp { Shell.open(["warp://session/\(u)"]) }
    }

    func fetchBase(_ w: Worktree) { action("Fetching \(w.base_sync?.base ?? "base")…", ["fetch", w.path]) }
    func reveal(_ w: Worktree) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.path)]) }
    var jiraURL: String? { data?.config?.jira_url.flatMap { $0.isEmpty ? nil : $0 } }
    func openJira(_ key: String) {
        guard let base = jiraURL else { return }
        Shell.open(["\(base.hasSuffix("/") ? String(base.dropLast()) : base)/browse/\(key)"])
    }

    func remove(_ w: Worktree) { remove([w]) }

    func remove(_ ws: [Worktree]) {
        guard !ws.isEmpty, busy == nil else { return }
        let ok = ws.filter(\.removable)
        let blocked = ws.filter { !$0.removable }
        let blockedText = blocked.map { "• \($0.title) — \($0.remove_blockers.joined(separator: "; "))" }
            .joined(separator: "\n")
        guard !ok.isEmpty else {
            Alerts.info(ws.count == 1 ? "Can't remove \(ws[0].title)" : "None of the \(ws.count) worktrees can be removed",
                        "Nothing is removed while something could be lost:\n\n" + blockedText)
            return
        }
        var body = "Frees ≈ \(gbText(ok.reduce(0) { $0 + $1.gb })). Local branches are kept.\n\n"
            + ok.prefix(15).map { "• \($0.title)  —  \($0.repo)" }.joined(separator: "\n")
            + (ok.count > 15 ? "\n… and \(ok.count - 15) more" : "")
        if !blocked.isEmpty { body += "\n\nSkipped (\(blocked.count)):\n" + blockedText }
        let title = ok.count == 1 ? "Remove \(ok[0].title)?" : "Remove \(ok.count) worktrees?"
        if Alerts.confirm(title, body, button: ok.count == 1 ? "Remove" : "Remove \(ok.count)") {
            removeConfirmed(ok, deleteBranches: false)
        }
    }

    func removeConfirmed(_ ok: [Worktree], deleteBranches: Bool, force: Bool = false) {
        guard !ok.isEmpty else { return }
        action(ok.count == 1 ? "Removing \(ok[0].title)…" : "Removing \(ok.count)…",
               ["remove"] + ok.map(\.path) + ["--yes"] + (deleteBranches ? ["--delete-branch"] : []) + (force ? ["--force"] : []),
               hiding: Set(ok.map(\.path)), report: force)
    }

    /// Asks once for every worktree that needs --force; returns false when the person cancels.
    func confirmForce(_ forced: [Worktree]) -> Bool {
        guard !forced.isEmpty else { return true }
        let list = forced.prefix(12).map { "• \($0.title) — \($0.forceLoss)" }.joined(separator: "\n")
            + (forced.count > 12 ? "\n… and \(forced.count - 12) more" : "")
        return Alerts.confirm(forced.count == 1 ? "Force remove \(forced[0].title)?" : "Force remove \(forced.count) worktrees?",
                              "\(list)\n\nTheir uncommitted and untracked files are deleted from the worktree. "
                              + "A backup (changes.patch + untracked files + restore steps) is saved first to "
                              + "~/Library/Application Support/git-worktree-tracker/backups. Local branches are kept.",
                              button: "Force Remove")
    }

    func forceRemove(_ ws: [Worktree]) {
        guard busy == nil else { return }
        let forced = ws.filter(\.forceRemovable)
        let hard = ws.filter { !$0.removable && !$0.forceRemovable }
        guard !forced.isEmpty else {
            Alerts.info("Can't force remove", hard.map { "• \($0.title) — \(($0.force_blockers ?? []).joined(separator: "; "))" }
                .joined(separator: "\n"))
            return
        }
        if confirmForce(forced) {
            removeConfirmed(ws.filter(\.removable) + forced, deleteBranches: false, force: true)
        }
    }

    /// NSOpenPanel → `wt.py config --set-bases …` → rescan.
    func chooseFolders() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Folders that hold your git repos"
        panel.message = "Repos up to 3 levels deep are found; their worktrees are discovered wherever they live."
        panel.prompt = "Use Folders"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        setBases(panel.urls.map(\.path))
    }

    func setBases(_ paths: [String]) {
        busy = "Scanning…"
        Task {
            let (code, _, err) = await Shell.run("/usr/bin/python3", [script, "config", "--set-bases"] + paths)
            busy = nil
            if code != 0 { Alerts.info("Could not save the folders", err) }
            data = nil
            loading = false
            refresh(withSizes: true)
        }
    }

    func stopProcesses(_ w: Worktree) {
        let list = w.procs.map { "\($0.pid)  \($0.cmd ?? $0.name ?? "")" }.joined(separator: "\n")
        if Alerts.confirm("Stop \(w.procs.count) process(es) in \(w.title)?", list, button: "Send SIGTERM") {
            action("Stopping…", ["kill", w.path, "--yes"])
        }
    }
}

enum Shell {
    static func run(_ exe: String, _ args: [String]) async -> (Int32, String, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                var errData = Data()
                let errDone = DispatchSemaphore(value: 0)
                do { try p.run() } catch {
                    cont.resume(returning: (-1, "", "\(error)"))
                    return
                }
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    errDone.signal()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                errDone.wait()
                cont.resume(returning: (p.terminationStatus,
                                        String(decoding: outData, as: UTF8.self),
                                        String(decoding: errData, as: UTF8.self)))
            }
        }
    }

    static func open(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        try? p.run()
    }
}

enum Alerts {
    static func confirm(_ title: String, _ body: String, button: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .warning
        a.addButton(withTitle: button).hasDestructiveAction = true
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    static func info(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.runModal()
    }
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

// MARK: - Components

enum ButtonKind { case primary, secondary, danger, invert }

struct TButtonStyle: ButtonStyle {
    var kind: ButtonKind = .secondary
    var height: CGFloat = 36
    var square = false

    func makeBody(configuration: Configuration) -> some View {
        TButtonBody(configuration: configuration, kind: kind, height: height, square: square)
    }
}

private struct TButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: ButtonKind
    let height: CGFloat
    let square: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        let (bg, fg, border): (Color, Color, Color) = {
            switch kind {
            case .primary: return (T.accent, T.onAccent, .clear)
            case .danger: return (T.dangerSoft, T.danger, T.dangerBorder)
            case .invert: return (T.fg, T.bg, .clear)
            case .secondary: return (hover ? T.controlHover : T.control, T.fg, T.hair)
            }
        }()
        configuration.label
            .font(F.ui(13, kind == .secondary ? .medium : .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, square ? 0 : 14)
            .frame(width: square ? height : nil, height: height)
            .frame(maxWidth: kind == .invert ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(border))
            .overlay {
                if kind == .primary {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center))
                }
            }
            .brightness(configuration.isPressed ? -0.06 : (hover && kind != .secondary ? 0.04 : 0))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

struct Chip: View {
    let text: String
    let tone: Tone
    var radius: CGFloat = 99

    var body: some View {
        Text(text)
            .font(F.ui(11.5, .semibold))
            .lineLimit(1)
            .padding(.horizontal, radius > 10 ? 9 : 7)
            .padding(.vertical, radius > 10 ? 3 : 1.5)
            .foregroundStyle(tone.fg)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tone.bg))
    }
}

struct Glyph: View {
    let state: String
    var size: CGFloat = 30

    var body: some View {
        let st = StateStyle.of(state)
        Image(systemName: st.symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(st.tone.fg)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(st.tone.bg))
    }
}

struct SectionBox<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(title)
            }
            .font(F.ui(12, .semibold))
            .foregroundStyle(T.muted)
            content
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(T.section))
    }
}

struct Tile: View {
    let label: String
    let value: String
    var tint: Color = T.fg
    var big: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(F.ui(11.5, .medium)).foregroundStyle(T.subtle)
            Text(value).font(F.ui(big, big > 18 ? .bold : .semibold)).monospacedDigit().foregroundStyle(tint).lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.section))
    }
}

extension View {
    func panel(_ radius: CGFloat = 16) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(T.panel))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(T.hairSoft))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Main window

enum Filter: Hashable {
    case all
    case running
    case attention
    case state(String)
    case repo(String)
}

enum GroupBy: String, CaseIterable { case status = "Status", repository = "Repository", recent = "Recent" }

struct ListGroup: Identifiable {
    let id: String
    let label: String
    let items: [Worktree]
}

struct MainView: View {
    @EnvironmentObject var store: Store
    @State private var filter: Filter = .all
    @State private var groupBy: GroupBy = .status
    @State private var selection: Set<String> = []
    @State private var anchor: String?
    @State private var query = ""
    @State private var showSidebar = true
    @State private var showCleanup = false
    @State private var showWelcome = false
    @State private var welcomed = false
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    var filtered: [Worktree] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.worktrees.filter { w in
            switch filter {
            case .all: break
            case .running: if w.procs.isEmpty { return false }
            case .attention: if !w.attention { return false }
            case .state(let s): if w.state != s { return false }
            case .repo(let r): if w.repo != r { return false }
            }
            guard !q.isEmpty else { return true }
            return [w.name, w.branch ?? "", w.ticket ?? "", w.repo].contains { $0.lowercased().contains(q) }
        }
    }

    var groups: [ListGroup] {
        let items = filtered
        switch groupBy {
        case .status:
            return stateOrder.compactMap { s in
                let g = items.filter { $0.state == s }
                return g.isEmpty ? nil : ListGroup(id: s, label: StateStyle.of(s).title, items: g)
            }
        case .repository:
            return Dictionary(grouping: items, by: \.repo)
                .sorted { $0.value.count > $1.value.count }
                .map { ListGroup(id: $0.key, label: $0.key,
                                 items: $0.value.sorted { ($0.git.activity_ts ?? 0) > ($1.git.activity_ts ?? 0) }) }
        case .recent:
            let now = Date().timeIntervalSince1970
            let sorted = items.sorted { ($0.git.activity_ts ?? 0) > ($1.git.activity_ts ?? 0) }
            let buckets: [(String, (Double) -> Bool)] = [
                ("Today", { $0 < 86400 }), ("This week", { $0 >= 86400 && $0 < 7 * 86400 }), ("Older", { $0 >= 7 * 86400 }),
            ]
            return buckets.compactMap { label, test in
                let g = sorted.filter { test(now - Double($0.git.activity_ts ?? 0)) }
                return g.isEmpty ? nil : ListGroup(id: label, label: label, items: g)
            }
        }
    }

    var flat: [Worktree] { groups.flatMap(\.items) }
    var selected: [Worktree] { store.worktrees.filter { selection.contains($0.path) } }

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                SidebarView(filter: $filter, showCleanup: $showCleanup) { withAnimation(.snappy) { showSidebar = false } }
                    .frame(width: 248)
                    .padding(8)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(spacing: 0) {
                toolbar
                HStack(alignment: .top, spacing: 8) {
                    listPanel.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                    detailPanel.frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
                }
                .padding(.leading, showSidebar ? 0 : 8)
                .padding([.trailing, .bottom], 8)
            }
        }
        .background(T.bg)
        .ignoresSafeArea()
        .font(F.ui(13))
        .foregroundStyle(T.fg)
        .sheet(isPresented: $showCleanup) { CleanupSheet().environmentObject(store) }
        .sheet(isPresented: $showWelcome) { WelcomeSheet().environmentObject(store) }
        .onAppear { DispatchQueue.main.async { listFocused = true } }
        .background(shortcuts)
        .onChange(of: store.data?.generated_at) {
            if !welcomed, store.data?.configured == false, Store.fixture == nil, Snapshot.path == nil || Snapshot.args.contains("--welcome") {
                welcomed = true
                showWelcome = true
            }
            selection = selection.intersection(Set(store.worktrees.map(\.path)))
            if selection.isEmpty, let ids = Snapshot.select {
                selection = Set(ids.split(separator: ",").compactMap { id in
                    store.worktrees.first { $0.name.localizedCaseInsensitiveContains(String(id)) }?.path
                })
            }
            if Snapshot.cleanup { showCleanup = true }
            if let g = Snapshot.group, let v = GroupBy(rawValue: g) { groupBy = v }
            Snapshot.schedule()
        }
    }

    var shortcuts: some View {
        ZStack {
            Button("") { searchFocused = true }.keyboardShortcut("k")
            Button("") { store.refresh(withSizes: true, force: true) }.keyboardShortcut("r")
            Button("") { selection = Set(flat.map(\.path)) }.keyboardShortcut("a").disabled(searchFocused)
            Button("") { store.remove(selected) }.keyboardShortcut(.delete, modifiers: .command).disabled(searchFocused)
            Button("") { withAnimation(.snappy) { showSidebar.toggle() } }.keyboardShortcut("s", modifiers: [.command, .control])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    // Toolbar

    var subtitle: String {
        guard let d = store.data else { return "Loading…" }
        return (["\(d.totals.count) worktrees"]
            + [("active", "active"), ("review", "in review"), ("merged", "merged")]
                .compactMap { store.count($0.0) > 0 ? "\(store.count($0.0)) \($0.1)" : nil })
            .joined(separator: " · ")
    }

    var toolbar: some View {
        HStack(spacing: 12) {
            if !showSidebar {
                Color.clear.frame(width: 64)
                Button { withAnimation(.snappy) { showSidebar = true } } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 14))
                }
                .buttonStyle(TButtonStyle(height: 32, square: true))
                .help("Show sidebar ⌃⌘S")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Worktrees").font(F.ui(15, .bold)).tracking(-0.15)
                Text(subtitle).font(F.ui(12)).foregroundStyle(T.muted).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if store.loading || store.busy != nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(store.busy ?? "Refreshing…").font(F.ui(12)).foregroundStyle(T.muted)
                }
            }
            SegmentedControl(value: $groupBy)
            editorMenu
            Button { store.refresh(withSizes: true, force: true) } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(TButtonStyle(height: 34, square: true))
            .help("Refresh ⌘R")
            searchField
        }
        .padding(.leading, 12).padding(.trailing, 16)
        .padding(.top, 14).padding(.bottom, 12)
        .frame(minHeight: 52)
    }

    var editorMenu: some View {
        Menu {
            ForEach(editors, id: \.id) { e in
                Button {
                    UserDefaults.standard.set(e.id, forKey: "editor")
                    store.objectWillChange.send()
                } label: {
                    if Store.editor.id == e.id { Label(e.label, systemImage: "checkmark") } else { Text(e.label) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 11, weight: .semibold))
                Text(Store.editor.label).font(F.ui(12, .medium))
            }
            .foregroundStyle(T.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.control))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(T.hair))
        .help("Editor used by Open")
    }

    var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(T.subtle)
            TextField("Ticket, branch, repo…", text: $query)
                .textFieldStyle(.plain)
                .font(F.ui(13))
                .focused($searchFocused)
                .onSubmit { listFocused = true }
                .onExitCommand { query = ""; searchFocused = false }
            if query.isEmpty {
                Text("⌘K").font(F.ui(11, .medium)).foregroundStyle(T.muted)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(T.well))
            } else {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(T.subtle) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.leading, 12).padding(.trailing, 10)
        .frame(minWidth: 180, idealWidth: 300, maxWidth: 300)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.control))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(searchFocused ? T.accentBorder : T.hair, lineWidth: searchFocused ? 1.5 : 1))
    }

    // List

    var listPanel: some View {
        Group {
            if store.data == nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Scanning worktrees…").foregroundStyle(T.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 26)).foregroundStyle(T.faint)
                    Text(query.isEmpty ? "No worktrees found" : "No match for “\(query)”").font(F.ui(14, .semibold))
                    if query.isEmpty {
                        Text("Scanning " + (store.data?.bases ?? []).map(tildePath).joined(separator: ", "))
                            .font(F.ui(12)).foregroundStyle(T.muted).multilineTextAlignment(.center)
                        Button("Choose folders…") { store.chooseFolders() }.buttonStyle(TButtonStyle(height: 30))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(groups) { g in
                                HStack(spacing: 8) {
                                    Text(g.label)
                                    Text("\(g.items.count)").monospacedDigit()
                                        .foregroundStyle(T.muted)
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Capsule().fill(T.well))
                                }
                                .font(F.ui(11, .semibold))
                                .foregroundStyle(T.subtle)
                                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
                                ForEach(g.items) { w in
                                    RowView(w: w, isSelected: selection.contains(w.path), selectionCount: selection.count,
                                            selectedItems: { selected })
                                        .id(w.path)
                                        .onTapGesture { click(w) }
                                }
                                Color.clear.frame(height: 6)
                            }
                        }
                        .padding(6)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: anchor) { if let a = anchor { proxy.scrollTo(a) } }
                }
            }
        }
        .panel()
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            store.remove(selected)
            return .handled
        }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            move(press.key == .upArrow ? -1 : 1, extend: press.modifiers.contains(.shift))
            return .handled
        }
        .onKeyPress(.return) {
            selected.prefix(3).forEach(store.openEditor)
            return .handled
        }
    }

    func click(_ w: Worktree) {
        listFocused = true
        if NSApp.currentEvent?.clickCount == 2 {
            store.openEditor(w)
            return
        }
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selection.contains(w.path) { selection.remove(w.path) } else { selection.insert(w.path) }
            anchor = w.path
        } else if mods.contains(.shift), let a = anchor,
                  let i = flat.firstIndex(where: { $0.path == a }), let j = flat.firstIndex(where: { $0.path == w.path }) {
            selection = Set(flat[min(i, j)...max(i, j)].map(\.path))
        } else {
            selection = [w.path]
            anchor = w.path
        }
    }

    func move(_ delta: Int, extend: Bool) {
        let list = flat
        guard !list.isEmpty else { return }
        let cur = anchor.flatMap { a in list.firstIndex { $0.path == a } } ?? (delta > 0 ? -1 : list.count)
        let next = min(max(cur + delta, 0), list.count - 1)
        let path = list[next].path
        if extend { selection.insert(path) } else { selection = [path] }
        anchor = path
    }

    // Detail

    var detailPanel: some View {
        Group {
            let sel = selected
            if sel.count == 1 {
                DetailView(w: sel[0])
            } else if sel.count > 1 {
                MultiSelectView(items: sel)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 34, weight: .light)).foregroundStyle(T.faint)
                    Text("No worktree selected").font(F.ui(16, .semibold))
                    Text("Pick one to see its git, PR and /dev state.\n⌘-click or ⇧-click to select several · ⌫ removes")
                        .font(F.ui(12.5)).foregroundStyle(T.muted).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .panel()
        .overlay(alignment: .bottom) {
            if let err = store.error {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(F.ui(12)).lineLimit(3)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(T.dangerSoft))
                    .foregroundStyle(T.danger)
                    .padding()
            }
        }
    }
}

struct SegmentedControl: View {
    @Binding var value: GroupBy

    var body: some View {
        HStack(spacing: 0) {
            ForEach(GroupBy.allCases, id: \.self) { g in
                Button { withAnimation(.snappy(duration: 0.2)) { value = g } } label: {
                    Text(g.rawValue)
                        .font(F.ui(12, value == g ? .semibold : .medium))
                        .foregroundStyle(value == g ? T.fg : T.muted)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            if value == g {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(dyn(oklch(1, 0, 0), oklch(0.34, 0.011, 250)))
                                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(dyn(oklch(0.95, 0.004, 250), oklch(0.22, 0.010, 250))))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(T.hairSoft))
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var store: Store
    @Binding var filter: Filter
    @Binding var showCleanup: Bool
    let hide: () -> Void

    var repos: [(String, Int)] {
        Dictionary(grouping: store.worktrees, by: \.repo).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Spacer()
                Button(action: hide) { Image(systemName: "sidebar.left").font(.system(size: 14)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(T.muted)
                    .frame(width: 28, height: 28)
                    .help("Hide sidebar ⌃⌘S")
            }
            .frame(height: 28)
            .padding(.horizontal, 6)

            nav("Status") {
                NavRow(icon: "square.stack.3d.up.fill", tint: T.accentText, label: "All worktrees",
                       count: store.worktrees.count, on: filter == .all) { filter = .all }
                ForEach(stateOrder.filter { store.count($0) > 0 }, id: \.self) { s in
                    let st = StateStyle.of(s)
                    NavRow(icon: st.symbol, tint: st.tone.fg, label: st.title, count: store.count(s),
                           on: filter == .state(s)) { filter = filter == .state(s) ? .all : .state(s) }
                }
                let attn = store.worktrees.filter(\.attention).count
                if attn > 0 {
                    NavRow(icon: "exclamationmark.triangle.fill", tint: T.danger, label: "Needs attention", count: attn,
                           on: filter == .attention) { filter = filter == .attention ? .all : .attention }
                }
                NavRow(icon: "gauge.with.dots.needle.67percent", tint: T.danger, label: "Running", count: store.running.count,
                       on: filter == .running) { filter = filter == .running ? .all : .running }
            }
            nav("Repositories") {
                ForEach(repos, id: \.0) { repo, n in
                    NavRow(dot: RepoStyle.of(repo).dot, label: repo, count: n,
                           on: filter == .repo(repo)) { filter = filter == .repo(repo) ? .all : .repo(repo) }
                }
            }
            nav("Folders") {
                ForEach(store.data?.bases ?? [], id: \.self) { b in
                    HStack(spacing: 10) {
                        Image(systemName: "folder").font(.system(size: 12, weight: .semibold)).foregroundStyle(T.muted).frame(width: 16)
                        Text(tildePath(b)).font(F.ui(12.5)).foregroundStyle(T.muted).lineLimit(1).truncationMode(.head)
                    }
                    .padding(.horizontal, 10).frame(height: 26)
                    .help(b)
                }
                Button { store.chooseFolders() } label: {
                    Label("Change folders…", systemImage: "folder.badge.gearshape").font(F.ui(12.5, .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(T.accentText)
                .padding(.horizontal, 10).frame(height: 26)
            }
            Spacer(minLength: 0)
            if !store.running.isEmpty { ResourcesCard { filter = .running } }
            if store.data != nil { StorageCard(showCleanup: $showCleanup) }
        }
        .padding(EdgeInsets(top: 6, leading: 10, bottom: 10, trailing: 10))
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(T.sidebar))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(T.hair))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 10)
    }

    func nav<C: View>(_ title: String, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(F.ui(11, .semibold)).tracking(0.2).foregroundStyle(T.subtle)
                .padding(.horizontal, 10).padding(.bottom, 6)
            rows()
        }
    }
}

struct NavRow: View {
    var icon: String? = nil
    var tint: Color = T.muted
    var dot: Color? = nil
    let label: String
    let count: Int
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint).frame(width: 16)
                } else if let dot {
                    RoundedRectangle(cornerRadius: 3).fill(dot).frame(width: 10, height: 10).frame(width: 16)
                }
                Text(label).font(F.ui(13, on ? .semibold : .medium)).foregroundStyle(T.fg).lineLimit(1)
                Spacer()
                Text("\(count)").font(F.ui(12)).monospacedDigit().foregroundStyle(T.muted)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? T.navOn : hover ? T.navHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct ResourcesCard: View {
    @EnvironmentObject var store: Store
    let showAll: () -> Void

    var body: some View {
        let run = store.running
        let kb = run.reduce(0) { $0 + $1.rssKB }
        let cpu = run.reduce(0) { $0 + $1.cpu }

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Running").font(F.ui(12, .semibold))
                LiveDot(compact: true).help("Live · sampled every second")
                Spacer()
                Text("\(memText(kb)) · \(cpuText(cpu))").font(F.ui(12)).monospacedDigit().foregroundStyle(T.danger)
                    .lineLimit(1).fixedSize()
            }
            ForEach(run.prefix(4)) { w in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(w.title).font(F.ui(12, .medium)).lineLimit(1)
                        Spacer()
                        Text(w.usage).font(F.ui(11.5)).monospacedDigit().foregroundStyle(T.muted)
                    }
                    Sparkline(values: (store.history[w.path] ?? []).map(\.cpu), color: T.accentText,
                              ceiling: max(100, (store.history[w.path] ?? []).map(\.cpu).max() ?? 0))
                        .frame(height: 18)
                        .help("CPU, last 2 minutes")
                }
            }
            if run.count > 4 {
                Button("+ \(run.count - 4) more", action: showAll).buttonStyle(.plain).font(F.ui(11.5)).foregroundStyle(T.accentText)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(dyn(oklch(1, 0, 0, 0.7), oklch(0.16, 0.008, 250, 0.6))))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(T.hairSoft))
        .contentShape(Rectangle())
        .onTapGesture(perform: showAll)
        .help("Show only worktrees with running processes")
    }
}

struct StorageCard: View {
    @EnvironmentObject var store: Store
    @Binding var showCleanup: Bool

    var body: some View {
        let d = store.data!
        let total = max(d.disk.total_gb, 1)
        let used = total - d.disk.free_gb
        let nm = d.totals.artifacts_gb
        let reclaim = store.pruneCandidates.reduce(0) { $0 + $1.gb }
        let cands = store.cleanupCandidates.count

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Disk").font(F.ui(12, .semibold))
                Spacer()
                Text("\(Int(d.disk.free_gb)) GB free of \(Int(total)) GB").font(F.ui(12)).monospacedDigit().foregroundStyle(T.muted)
            }
            GeometryReader { geo in
                let w = geo.size.width
                HStack(spacing: 2) {
                    Rectangle().fill(T.diskOther).frame(width: max(0, w * (used - nm) / total))
                    Rectangle().fill(T.diskNM).frame(width: max(0, w * (nm - reclaim) / total))
                    Rectangle().fill(T.diskReclaim).frame(width: max(0, w * reclaim / total))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 8)
            .background(T.well)
            .clipShape(Capsule())
            .help("\(Int(used / total * 100))% used")
            VStack(spacing: 6) {
                legend(T.diskNM, "Deps & builds", gbText(nm), T.fg)
                legend(T.diskReclaim, "Reclaimable", gbText(reclaim), T.amber)
            }
            Button { showCleanup = true } label: {
                Label(cands == 0 ? "Nothing to clean" : "Clean up \(plural(cands, "worktree"))", systemImage: "sparkles")
                    .labelStyle(GapLabel())
            }
            .buttonStyle(TButtonStyle(kind: .invert))
            .disabled(cands == 0 || store.busy != nil)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(dyn(oklch(1, 0, 0, 0.7), oklch(0.16, 0.008, 250, 0.6))))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(T.hairSoft))
    }

    func legend(_ c: Color, _ k: String, _ v: String, _ emphasized: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 8)
            Text(k).foregroundStyle(T.muted)
            Spacer()
            Text(v).monospacedDigit().fontWeight(k == "Reclaimable" ? .semibold : .regular).foregroundStyle(emphasized)
        }
        .font(F.ui(12))
    }
}

// MARK: - Row

struct RowView: View {
    @EnvironmentObject var store: Store
    let w: Worktree
    let isSelected: Bool
    let selectionCount: Int
    let selectedItems: () -> [Worktree]
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Glyph(state: w.state).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(w.title).font(F.ui(14, .semibold)).tracking(-0.14).lineLimit(1).fixedSize()
                    let rs = RepoStyle.of(w.repo)
                    Chip(text: rs.short, tone: rs.tone, radius: 6).fixedSize()
                    Spacer(minLength: 4)
                    if let b = w.base_sync, b.behind > 0 {
                        Chip(text: "↓\(b.behind)", tone: Tone(fg: T.amber, bg: T.amberSoft), radius: 6).fixedSize()
                            .help("\(b.behind) commit(s) behind origin/\(b.base)")
                    }
                    if let pr = w.pr {
                        let (label, tone) = w.pr_status.map { let t = prStatusTone($0); return (t.0, t.1) } ?? prTone(pr)
                        Chip(text: "#\(String(pr.number)) \(label == "changes requested" ? "changes" : label)", tone: tone).fixedSize()
                    }
                }
                HStack(spacing: 8) {
                    Text(w.branchLabel).font(F.mono(12)).foregroundStyle(T.muted).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text((w.artifacts.kind == "dir" ? sizeText(w.artifacts) + " · " : "") + relative(w.git.activity_ts))
                        .font(F.ui(12)).monospacedDigit().foregroundStyle(T.subtle).fixedSize()
                }
                if w.dirty > 0 || !w.procs.isEmpty || w.run != nil || !(w.sessions ?? []).isEmpty {
                    HStack(spacing: 10) {
                        if w.dirty > 0 {
                            HStack(spacing: 5) {
                                Circle().fill(T.amber).frame(width: 6, height: 6)
                                Text("\(w.dirty) changed")
                            }
                            .foregroundStyle(T.amber)
                            .fixedSize()
                        }
                        if !w.procs.isEmpty {
                            Label(w.usage, systemImage: "gauge.with.dots.needle.67percent").foregroundStyle(T.danger)
                                .fixedSize()
                                .help("\(plural(w.procs.count, "process")) running in this worktree")
                        }
                        if let stage = w.run?.stage {
                            Label(stage, systemImage: "flag.fill").foregroundStyle(T.accentText).fixedSize()
                        }
                        if let s = w.sessions?.first {
                            Label(shortSession(s), systemImage: "sparkle")
                                .foregroundStyle(s.status == "busy" ? T.green : T.muted)
                                .fixedSize()
                                .help("Claude session \(s.name ?? "") (\(s.status ?? "?")) touched this worktree \(relative(s.last_ts))")
                        }
                        Spacer(minLength: 0)
                    }
                    .font(F.ui(12))
                    .lineLimit(1)
                    .labelStyle(TightLabel())
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isSelected ? T.accentSoft : hover ? T.hover : .clear))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isSelected ? T.accentBorder : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            if isSelected && selectionCount > 1 {
                Button("Remove \(selectionCount) worktrees…", role: .destructive) { store.remove(selectedItems()) }
            } else {
                WorktreeMenu(w: w)
            }
        }
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 10, weight: .bold))
            configuration.title
        }
    }
}

struct GapLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.font(.system(size: 13, weight: .semibold))
            configuration.title
        }
    }
}

struct WorktreeMenu: View {
    @EnvironmentObject var store: Store
    let w: Worktree

    var body: some View {
        ForEach(editors, id: \.id) { e in
            Button("Open in \(e.label)") { Shell.open(["-b", e.app, w.path]) }
        }
        Button(w.warp == nil ? "Open in Warp" : "Jump to Warp tab") { store.openTerminal(w) }
        Button("New Warp tab here") { store.openNewWarpTab(w) }
        Button("Reveal in Finder") { store.reveal(w) }
        Divider()
        if let pr = w.pr { Button("Open PR #" + String(pr.number)) { Shell.open([pr.url]) } }
        if let t = w.ticket, store.jiraURL != nil { Button("Open \(t) in Jira") { store.openJira(t) } }
        Button("Copy path") { copyToPasteboard(w.path) }
        if let b = w.branch { Button("Copy branch") { copyToPasteboard(b) } }
        Divider()
        if !w.procs.isEmpty { Button("Stop processes…") { store.stopProcesses(w) } }
        Button("Remove worktree…", role: .destructive) { store.remove(w) }
        if w.forceRemovable {
            Button("Force remove (backup changes)…", role: .destructive) { store.forceRemove([w]) }
        }
    }
}

// MARK: - Detail

struct DetailView: View {
    @EnvironmentObject var store: Store
    let w: Worktree
    @State private var showFiles = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                actions
                if Snapshot.args.contains("--procs-first"), !w.procs.isEmpty { procSection }
                HStack(spacing: 8) {
                    Tile(label: "Working tree", value: w.dirty == 0 ? "Clean" : "\(w.dirty) changed",
                         tint: w.dirty == 0 ? T.green : T.amber)
                    Tile(label: w.artifacts.label, value: sizeText(w.artifacts))
                        .help(w.artifacts.breakdown.isEmpty ? "No git-ignored dependency or build folders" : w.artifacts.breakdown)
                    Tile(label: "Last activity", value: relative(w.git.activity_ts))
                    if !w.procs.isEmpty {
                        Tile(label: "RAM · CPU", value: w.usage, tint: T.danger)
                    }
                }
                gitSection
                if let pr = w.pr { prSection(pr) }
                if let r = w.run { runSection(r) }
                if !(w.sessions ?? []).isEmpty { sessionsSection }
                if !w.procs.isEmpty { procSection }
                cleanupSection
            }
            .padding(24)
        }
        .scrollIndicators(.never)
    }

    var hero: some View {
        HStack(alignment: .top, spacing: 16) {
            Glyph(state: w.state, size: 56)
            VStack(alignment: .leading, spacing: 8) {
                Text(w.title).font(F.ui(24, .bold)).tracking(-0.48).textSelection(.enabled)
                HStack(spacing: 6) {
                    Chip(text: w.repo, tone: RepoStyle.of(w.repo).tone)
                    let st = StateStyle.of(w.state)
                    Chip(text: st.title, tone: st.tone)
                    ForEach(w.ecosystems ?? [], id: \.self) { Chip(text: $0, tone: Tone(fg: T.muted, bg: T.well)) }
                    if let pr = w.pr {
                        let (label, tone) = w.pr_status.map { let t = prStatusTone($0); return (t.0, t.1) } ?? prTone(pr)
                        Chip(text: "#\(String(pr.number)) · \(label)", tone: tone)
                    }
                }
                Text(summary).font(F.ui(13)).foregroundStyle(T.muted)
            }
            Spacer(minLength: 0)
        }
    }

    var summary: String {
        (w.dirty > 0 ? "\(w.dirty) uncommitted file(s)" : "Clean working tree") + " · last touched " + relative(w.git.activity_ts)
    }

    var actions: some View {
        HStack(spacing: 8) {
            Button { store.openEditor(w) } label: {
                Label("Open in \(Store.editor.label)", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .buttonStyle(TButtonStyle(kind: .primary))
            Button { store.openTerminal(w) } label: {
                Label(!hasWarp ? "Terminal" : w.warp == nil ? "New Warp tab" : "Warp tab", systemImage: "apple.terminal")
            }
            .buttonStyle(TButtonStyle())
            .help(w.warp.map { "Jump to the Warp pane of \($0.source == "claude" ? "Claude session " : "")\($0.label ?? "")" }
                  ?? "No Warp pane is on this worktree — opens a new tab there")
            Button { store.reveal(w) } label: { Label("Finder", systemImage: "folder") }
                .buttonStyle(TButtonStyle())
            if let t = w.ticket, store.jiraURL != nil {
                Button { store.openJira(t) } label: { Label("Jira", systemImage: "arrow.up.forward.square") }
                    .buttonStyle(TButtonStyle())
            }
            Spacer(minLength: 0)
            Menu { WorktreeMenu(w: w) } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold)).foregroundStyle(T.fg)
                    .frame(width: 36, height: 36)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.control))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(T.hair))
        }
        .labelStyle(GapLabel())
    }

    var gitSection: some View {
        SectionBox(title: "Git", symbol: "arrow.triangle.branch") {
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 12) {
                row("Branch") { Text(w.branchLabel).font(F.mono(12.5)).textSelection(.enabled) }
                if let c = w.git.last_commit {
                    row("Last commit") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(c.subject).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                            Text("\(c.sha) · \(relative(c.ts))").font(F.mono(11.5)).foregroundStyle(T.subtle)
                        }
                    }
                }
                row("Upstream") {
                    if let up = w.git.upstream {
                        HStack(spacing: 6) {
                            Text(up).font(F.mono(12.5))
                            if let a = w.git.ahead, a > 0 { Chip(text: "↑\(a)", tone: Tone(fg: T.blue, bg: T.blueSoft), radius: 6) }
                            if let b = w.git.behind, b > 0 { Chip(text: "↓\(b)", tone: Tone(fg: T.amber, bg: T.amberSoft), radius: 6) }
                        }
                    } else {
                        Text("none").foregroundStyle(T.subtle)
                    }
                }
                if let u = w.git.unpushed, u > 0 {
                    row("Unpushed") { Text("\(plural(u, "commit")) on no remote branch").foregroundStyle(T.amber) }
                }
                row("Path") {
                    HStack(alignment: .top, spacing: 8) {
                        Text(w.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(F.mono(11.5)).foregroundStyle(T.muted).lineSpacing(3)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Button { copyToPasteboard(w.path) } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 12)).foregroundStyle(T.subtle)
                                .frame(width: 26, height: 26).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Copy path")
                    }
                }
            }
            .font(F.ui(13))
        }
    }

    func row<V: View>(_ key: String, @ViewBuilder _ value: () -> V) -> some View {
        GridRow {
            Text(key).foregroundStyle(T.subtle).frame(width: 96, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func prSection(_ pr: PullRequest) -> some View {
        let (label, tone) = prTone(pr)
        return SectionBox(title: "Pull request", symbol: "arrow.triangle.pull") {
            Button { Shell.open([pr.url]) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("#" + String(pr.number)).font(F.ui(14, .bold)).foregroundStyle(tone.fg)
                    Text(pr.title ?? "").font(F.ui(14)).foregroundStyle(T.fg).multilineTextAlignment(.leading)
                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.forward.square").font(.system(size: 13)).foregroundStyle(T.subtle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
                if let st = w.pr_status {
                    let (l, t, icon) = prStatusTone(st)
                    HStack(spacing: 5) { Image(systemName: icon).font(.system(size: 10, weight: .bold)); Text(l.capitalized) }
                        .font(F.ui(11.5, .semibold)).foregroundStyle(t.fg)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Capsule().fill(t.bg))
                } else {
                    Chip(text: label.capitalized, tone: tone)
                }
                if let base = pr.baseRefName { Chip(text: "→ \(base)", tone: Tone(fg: T.muted, bg: T.well)) }
                if let st = w.pr_status, let r = st.reviews, r > 0 { Chip(text: plural(r, "review"), tone: Tone(fg: T.muted, bg: T.well)) }
                Spacer(minLength: 0)
                if let at = w.pr_status?.at { Text("checked \(relative(at))").font(F.ui(11)).foregroundStyle(T.subtle) }
            }
            if let st = w.pr_status {
                if let next = st.next, st.state != "MERGED" {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(T.accentText)
                        Text(next).font(F.ui(12.5)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let checks = st.checks, !checks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(checks.sorted { checkRank($0.bucket) < checkRank($1.bucket) }, id: \.self) { c in
                            Button { if let l = c.link, !l.isEmpty { Shell.open([l]) } } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: checkIcon(c.bucket)).font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(checkColor(c.bucket)).frame(width: 14)
                                    Text(c.name).font(F.ui(12.5)).foregroundStyle(T.fg).lineLimit(1)
                                    Spacer()
                                    Text(c.bucket).font(F.ui(11)).foregroundStyle(T.subtle)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(dyn(oklch(1, 0, 0), oklch(0.18, 0.008, 250))))
                } else if st.state != "MERGED" {
                    Text("No CI checks reported for this repo.").font(F.ui(12)).foregroundStyle(T.subtle)
                }
            }
            if let b = w.base_sync {
                HStack(spacing: 10) {
                    Image(systemName: b.behind > 0 ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(b.behind > 0 ? T.amber : T.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.behind > 0 ? "\(plural(b.behind, "commit")) behind origin/\(b.base)" : "Up to date with origin/\(b.base)")
                            .font(F.ui(12.5, .semibold))
                        Text("\(b.ahead) ahead · as of fetch \(relative(b.fetched_ts))").font(F.ui(11.5)).foregroundStyle(T.subtle)
                    }
                    Spacer()
                    Button("Fetch") { store.fetchBase(w) }
                        .buttonStyle(TButtonStyle(height: 30))
                        .disabled(store.busy != nil)
                        .help("git fetch origin \(b.base) — read-only towards GitHub")
                }
            }
        }
    }

    func checkRank(_ b: String) -> Int { ["fail": 0, "cancel": 1, "pending": 2, "pass": 3, "skipping": 4][b] ?? 5 }
    func checkIcon(_ b: String) -> String {
        switch b { case "pass": return "checkmark.circle.fill"; case "fail", "cancel": return "xmark.circle.fill"
        case "pending": return "clock.fill"; default: return "minus.circle" }
    }
    func checkColor(_ b: String) -> Color {
        switch b { case "pass": return T.green; case "fail", "cancel": return T.danger; case "pending": return T.amber; default: return T.subtle }
    }

    var sessionsSection: some View {
        SectionBox(title: "Claude sessions on this worktree", symbol: "sparkle") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(w.sessions ?? [], id: \.pid) { s in
                    HStack(spacing: 10) {
                        Circle().fill(s.status == "busy" ? T.green : T.faint).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name ?? "session \(s.pid)").font(F.ui(13, .semibold))
                            Text("\(s.status ?? "?") · touched this worktree \(relative(s.last_ts)) · pid \(s.pid)")
                                .font(F.ui(11.5)).foregroundStyle(T.subtle)
                        }
                        Spacer()
                        Button { store.jump(s) } label: { Label("Jump to tab", systemImage: "arrow.up.right.square") }
                            .buttonStyle(TButtonStyle(height: 30))
                            .labelStyle(GapLabel())
                            .disabled(s.warp == nil)
                    }
                }
            }
        }
    }

    func runSection(_ r: RunInfo) -> some View {
        SectionBox(title: "/dev run", symbol: "flag.checkered") {
            HStack(spacing: 6) {
                if let s = r.stage { Chip(text: s, tone: Tone(fg: T.accentText, bg: T.accentSoft)) }
                if let s = r.status {
                    Chip(text: s, tone: s == "active" ? Tone(fg: T.green, bg: T.greenSoft)
                         : s == "blocked" ? Tone(fg: T.danger, bg: T.dangerSoft) : Tone(fg: T.amber, bg: T.amberSoft))
                }
                if let u = r.updated { Text("updated \(u)").font(F.ui(12)).foregroundStyle(T.subtle) }
            }
            if let n = r.next_action {
                Text(n).font(F.ui(13)).lineSpacing(2).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var procSection: some View {
        SectionBox(title: "Running processes", symbol: "gauge.with.dots.needle.67percent") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(plural(w.procs.count, "process")) · \(w.procs.filter { $0.child == true }.count) child")
                        .font(F.ui(12)).foregroundStyle(T.muted)
                    Spacer()
                    LiveDot()
                }
                let hist = store.history[w.path] ?? []
                HStack(spacing: 8) {
                    LiveChart(title: "CPU", samples: hist, value: \.cpu, format: cpuText, color: T.accentText)
                    LiveChart(title: "Memory", samples: hist, value: { Double($0.memKB) },
                              format: { memText(Int($0)) }, color: T.danger)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("PID"); Text("Process"); Text("RAM").gridColumnAlignment(.trailing)
                        Text("CPU").gridColumnAlignment(.trailing); Text("Up")
                    }
                    .font(F.ui(11, .semibold)).foregroundStyle(T.subtle)
                    ForEach(w.procs, id: \.pid) { p in
                        GridRow(alignment: .firstTextBaseline) {
                            Text(String(p.pid)).font(F.mono(11.5)).foregroundStyle(T.subtle)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    if p.child == true { Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(T.faint) }
                                    Text(p.name ?? "?").font(F.ui(13, .semibold))
                                    ForEach(p.ports, id: \.self) { Chip(text: ":\($0)", tone: Tone(fg: T.danger, bg: T.dangerSoft), radius: 6) }
                                }
                                Text(p.cmd ?? "").font(F.mono(11)).foregroundStyle(T.muted).lineLimit(1).truncationMode(.middle)
                                    .help(p.cmd ?? "")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(memText(p.rss_kb ?? 0)).font(F.ui(12.5)).monospacedDigit()
                            Text(cpuText(p.cpu ?? 0)).font(F.ui(12.5)).monospacedDigit()
                                .foregroundStyle((p.cpu ?? 0) > 50 ? T.danger : T.fg)
                            Text(p.etime ?? "").font(F.mono(11)).foregroundStyle(T.subtle)
                        }
                    }
                }
                HStack {
                    Button { store.stopProcesses(w) } label: { Label("Stop all", systemImage: "stop.circle") }
                        .buttonStyle(TButtonStyle(kind: .danger, height: 34))
                        .labelStyle(GapLabel())
                    Text("CPU 100% = one full core · memory = footprint, as in Activity Monitor").font(F.ui(11.5)).foregroundStyle(T.subtle)
                }
            }
        }
    }

    var cleanupSection: some View {
        SectionBox(title: "Cleanup", symbol: "trash") {
            HStack(alignment: .center, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: w.removable ? "checkmark" : "exclamationmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(w.removable ? T.green : T.amber)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(w.removable ? T.greenSoft : T.amberSoft))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cleanTitle).font(F.ui(13, .semibold))
                        Text(cleanBody).font(F.ui(12)).foregroundStyle(T.muted).lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !(w.git.files ?? []).isEmpty {
                    Button("Review files") { showFiles = true }
                        .buttonStyle(TButtonStyle(height: 34))
                        .popover(isPresented: $showFiles, arrowEdge: .bottom) { FilesPopover(w: w).environmentObject(store) }
                }
                if w.forceRemovable {
                    Button { store.forceRemove([w]) } label: { Label("Force remove…", systemImage: "trash.slash") }
                        .buttonStyle(TButtonStyle(kind: .danger, height: 34))
                        .labelStyle(GapLabel())
                        .disabled(store.busy != nil)
                        .help("Backs up changes.patch + untracked files to ~/Library/Application Support/git-worktree-tracker/backups, then removes")
                } else {
                    Button { store.remove(w) } label: { Label("Remove worktree", systemImage: "trash") }
                        .buttonStyle(TButtonStyle(kind: .danger, height: 34))
                        .labelStyle(GapLabel())
                        .disabled(!w.removable || store.busy != nil)
                }
            }
        }
    }

    var cleanTitle: String {
        if w.removable { return "Safe to remove" }
        if w.remove_blockers.count == 1 {
            let b = w.remove_blockers[0]
            return b.prefix(1).uppercased() + b.dropFirst() + " block removal"
        }
        return "\(w.remove_blockers.count) things block removal"
    }

    var cleanBody: String {
        if w.removable {
            return w.pr?.state == "MERGED"
                ? "PR merged and the tree is clean. Frees \(sizeText(w.artifacts)). The local branch is kept."
                : "Nothing uncommitted, unpushed or running. The local branch is kept."
        }
        let rest = w.remove_blockers.count > 1 ? w.remove_blockers.joined(separator: " · ") + ". " : ""
        if w.forceRemovable {
            return rest + "Commit or discard them — or force remove: the changes are backed up first."
        }
        return rest + "Can't be forced: " + (w.force_blockers ?? []).joined(separator: " · ") + "."
    }
}

struct FilesPopover: View {
    @EnvironmentObject var store: Store
    let w: Worktree

    var body: some View {
        let files = w.git.files ?? []
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(plural(files.count, "file")) in \(w.title)").font(F.ui(13, .semibold))
                Spacer()
                Text("\(w.git.modified ?? 0) modified · \(w.git.untracked ?? 0) untracked").font(F.ui(11.5)).foregroundStyle(T.subtle)
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(files, id: \.self) { f in
                        HStack(spacing: 8) {
                            let (label, tone) = badge(f.s)
                            Text(label).font(F.mono(10.5, .semibold)).foregroundStyle(tone.fg)
                                .frame(width: 22, height: 18)
                                .background(RoundedRectangle(cornerRadius: 4).fill(tone.bg))
                            Text(f.p).font(F.mono(11.5)).lineLimit(1).truncationMode(.head).textSelection(.enabled)
                        }
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 300)
            Divider()
            HStack(spacing: 8) {
                Spacer()
                Button("Terminal") { store.openTerminal(w) }.buttonStyle(TButtonStyle(height: 30))
                Button("Open in \(Store.editor.label)") { store.openEditor(w) }.buttonStyle(TButtonStyle(kind: .primary, height: 30))
            }
            .padding(12)
        }
        .frame(width: 460)
        .foregroundStyle(T.fg)
        .background(T.sheet)
    }

    func badge(_ s: String) -> (String, Tone) {
        if s == "??" { return ("U", Tone(fg: T.muted, bg: T.well)) }
        if s.contains("D") { return ("D", Tone(fg: T.danger, bg: T.dangerSoft)) }
        if s.contains("A") { return ("A", Tone(fg: T.green, bg: T.greenSoft)) }
        return ("M", Tone(fg: T.amber, bg: T.amberSoft))
    }
}

// MARK: - Multi-selection

struct MultiSelectView: View {
    @EnvironmentObject var store: Store
    let items: [Worktree]

    var body: some View {
        let ok = items.filter(\.removable)
        let blocked = items.filter { !$0.removable }
        let gb = ok.reduce(0) { $0 + $1.gb }
        let stack = Array(items.prefix(3).enumerated())

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 16) {
                    ZStack(alignment: .leading) {
                        ForEach(stack.reversed(), id: \.offset) { i, w in
                            Glyph(state: w.state, size: 48)
                                .background(RoundedRectangle(cornerRadius: 14.4, style: .continuous).fill(T.panel))
                                .overlay(RoundedRectangle(cornerRadius: 14.4, style: .continuous).strokeBorder(T.panel, lineWidth: 3))
                                .offset(x: CGFloat(i) * 16)
                        }
                    }
                    .frame(width: 48 + CGFloat(stack.count - 1) * 16, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(items.count) worktrees selected").font(F.ui(24, .bold)).tracking(-0.48)
                        Text("\(ok.count) removable · \(blocked.count) blocked · frees \(gbText(gb))")
                            .font(F.ui(13)).foregroundStyle(T.muted)
                    }
                }
                HStack(spacing: 8) {
                    Tile(label: "Removable", value: "\(ok.count)", tint: T.green)
                    Tile(label: "Frees", value: gbText(gb), tint: T.amber)
                    Tile(label: "Blocked", value: "\(blocked.count)", tint: blocked.isEmpty ? T.fg : T.amber)
                }
                HStack(spacing: 10) {
                    Button(role: .destructive) { store.remove(items) } label: {
                        Label(ok.isEmpty ? "Nothing removable" : "Remove \(plural(ok.count, "worktree"))", systemImage: "trash")
                    }
                    .buttonStyle(TButtonStyle(kind: .danger))
                    .labelStyle(GapLabel())
                    .disabled(ok.isEmpty || store.busy != nil)
                    let forceable = blocked.filter(\.forceRemovable)
                    if !forceable.isEmpty {
                        Button { store.forceRemove(items) } label: {
                            Label("Force remove \(plural(ok.count + forceable.count, "worktree"))…", systemImage: "trash.slash")
                        }
                        .buttonStyle(TButtonStyle(kind: .danger))
                        .labelStyle(GapLabel())
                        .disabled(store.busy != nil)
                    }
                    Text("or press ⌫").font(F.ui(12)).foregroundStyle(T.subtle)
                }
                if !ok.isEmpty {
                    SectionBox(title: "Will be removed", symbol: "checkmark.shield") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(ok) { w in line(w) }
                            Text("Local branches are kept.").font(F.ui(12)).foregroundStyle(T.subtle)
                        }
                    }
                }
                if !blocked.isEmpty {
                    SectionBox(title: "Will be skipped", symbol: "exclamationmark.octagon") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(blocked) { w in
                                VStack(alignment: .leading, spacing: 3) {
                                    line(w)
                                    Text(w.remove_blockers.joined(separator: " · "))
                                        .font(F.ui(12)).foregroundStyle(T.amber).padding(.leading, 32)
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .scrollIndicators(.never)
    }

    func line(_ w: Worktree) -> some View {
        HStack(spacing: 10) {
            Glyph(state: w.state, size: 22)
            Text(w.title).font(F.ui(13, .semibold))
            let rs = RepoStyle.of(w.repo)
            Chip(text: rs.short, tone: rs.tone, radius: 6)
            Spacer()
            Text(sizeText(w.artifacts)).font(F.ui(12)).monospacedDigit().foregroundStyle(T.subtle)
        }
    }
}

// MARK: - Welcome (first launch)

func tildePath(_ p: String) -> String { p.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

struct WelcomeSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let bases = store.data?.bases ?? []
        let repos = Set(store.worktrees.map(\.repo)).count
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(T.accentText)
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(T.accentSoft))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Worktrees").font(F.ui(20, .bold)).tracking(-0.2)
                    Text("Pick the folders that hold your git repos. Repos up to 3 levels deep are found, and their worktrees are discovered wherever they live. Nothing is changed until you remove something.")
                        .font(F.ui(13)).foregroundStyle(T.muted).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(bases.isEmpty ? "No common code folder found" : "Found automatically")
                    .font(F.ui(11.5, .semibold)).foregroundStyle(T.subtle)
                ForEach(bases, id: \.self) { b in
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").foregroundStyle(T.accentText)
                        Text(tildePath(b)).font(F.mono(12.5))
                    }
                }
                if !bases.isEmpty {
                    Text(store.worktrees.isEmpty
                         ? "No linked worktrees there yet — choose the folders your repos live in."
                         : "\(plural(store.worktrees.count, "worktree")) in \(plural(repos, "repo")) so far")
                        .font(F.ui(12)).foregroundStyle(T.muted)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.section))
            HStack(spacing: 10) {
                Spacer()
                if !bases.isEmpty {
                    Button("Use these") { store.setBases(bases); dismiss() }
                        .buttonStyle(TButtonStyle())
                }
                Button { dismiss(); DispatchQueue.main.async { store.chooseFolders() } } label: {
                    Label("Choose folders…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(TButtonStyle(kind: .primary))
                .labelStyle(GapLabel())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(T.sheet)
        .font(F.ui(13))
        .foregroundStyle(T.fg)
    }
}

// MARK: - Clean up sheet

struct CleanupSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var checked: Set<String> = []
    @State private var deleteBranches = false
    @State private var initialized = false

    var candidates: [Worktree] {
        store.cleanupCandidates.sorted {
            ($0.removable ? 1 : 0, -($0.git.activity_ts ?? 0)) < ($1.removable ? 1 : 0, -($1.git.activity_ts ?? 0))
        }
    }

    var body: some View {
        let cands = candidates
        let removable = cands.filter(\.removable)
        let picked = cands.filter { checked.contains($0.path) && ($0.removable || $0.forceRemovable) }
        let forced = picked.filter { !$0.removable }
        let gb = picked.reduce(0) { $0 + $1.gb }

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "sparkles").font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(T.amber)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(T.amberSoft))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Clean up merged worktrees").font(F.ui(18, .bold)).tracking(-0.18)
                    Text("\(plural(cands.count, "worktree")) \(cands.count == 1 ? "has" : "have") a merged or closed PR. Removing one deletes its folder and its dependency/build folders — the branch stays on origin. Tick an amber row to force it: its changes are backed up first.")
                        .font(F.ui(13)).foregroundStyle(T.muted).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(EdgeInsets(top: 24, leading: 24, bottom: 16, trailing: 24))

            HStack(spacing: 8) {
                Tile(label: "Selected", value: "\(picked.count)", big: 20)
                Tile(label: "Frees", value: gbText(gb), tint: T.amber, big: 20)
                Tile(label: "Need review", value: "\(cands.count - removable.count)", big: 20)
            }
            .padding(.horizontal, 24).padding(.bottom, 16)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Toggle(isOn: Binding(
                        get: { !removable.isEmpty && removable.allSatisfy { checked.contains($0.path) } },
                        set: { on in checked = on ? Set(removable.map(\.path)) : [] })) { EmptyView() }
                        .toggleStyle(.checkbox).labelsHidden()
                    Text("Worktree").frame(maxWidth: .infinity, alignment: .leading)
                    Text("PR").frame(width: 80, alignment: .leading)
                    Text("Size").frame(width: 64, alignment: .trailing)
                }
                .font(F.ui(11.5, .semibold))
                .foregroundStyle(T.subtle)
                .padding(.horizontal, 14).padding(.vertical, 10)
                Rectangle().fill(T.hairSoft).frame(height: 1)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(cands.enumerated()), id: \.element.path) { i, w in
                            if i > 0 { Rectangle().fill(T.hairSoft).frame(height: 1) }
                            cleanupRow(w)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(dyn(oklch(0.985, 0.003, 250), oklch(0.17, 0.008, 250))))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(T.hairSoft))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 24)

            HStack(spacing: 10) {
                Toggle(isOn: $deleteBranches) {
                    Text("Also delete local branches").font(F.ui(12.5)).foregroundStyle(T.muted)
                }
                .toggleStyle(.checkbox)
                .help("Deletes a branch only when git agrees it is merged, or its tip is exactly the merged PR head")
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(TButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Remove \(plural(picked.count, "worktree"))" + (forced.isEmpty ? "" : " · \(forced.count) forced")) {
                    guard store.confirmForce(forced) else { return }
                    store.removeConfirmed(picked, deleteBranches: deleteBranches, force: !forced.isEmpty)
                    dismiss()
                }
                .buttonStyle(TButtonStyle(kind: forced.isEmpty ? .primary : .danger))
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty || store.busy != nil)
            }
            .padding(EdgeInsets(top: 16, leading: 24, bottom: 20, trailing: 24))
        }
        .frame(width: 720, height: 660)
        .background(T.sheet)
        .font(F.ui(13))
        .foregroundStyle(T.fg)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            checked = Set(removable.map(\.path))
        }
    }

    func cleanupRow(_ w: Worktree) -> some View {
        let blocked = !w.removable
        let checkable = w.removable || w.forceRemovable
        let forcing = blocked && checked.contains(w.path)
        return HStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { checked.contains(w.path) },
                set: { on in if on { checked.insert(w.path) } else { checked.remove(w.path) } })) { EmptyView() }
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(!checkable)
                .help(checkable ? (blocked ? "Tick to force remove — changes are backed up first" : "")
                      : "Can't be forced: " + (w.force_blockers ?? []).joined(separator: "; "))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(w.title).font(F.ui(13, .semibold))
                    if forcing {
                        Chip(text: "force · backup", tone: Tone(fg: T.danger, bg: T.dangerSoft), radius: 6)
                    }
                    if blocked {
                        Text("· " + w.remove_blockers.joined(separator: " · ")).font(F.ui(12, .medium))
                            .foregroundStyle(checkable ? T.amber : T.danger).lineLimit(1)
                    }
                }
                Text(w.branchLabel).font(F.mono(11.5)).foregroundStyle(T.muted).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(w.pr.map { "#" + String($0.number) } ?? "—").font(F.ui(12, .semibold))
                .foregroundStyle(w.pr != nil ? T.purple : T.subtle)
                .frame(width: 80, alignment: .leading)
            Text(w.artifacts.kind == "dir" ? sizeText(w.artifacts) : "—").monospacedDigit().foregroundStyle(T.muted)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(forcing ? T.dangerSoft : blocked ? T.amberRow : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            guard checkable else { return }
            if checked.contains(w.path) { checked.remove(w.path) } else { checked.insert(w.path) }
        }
    }
}

// MARK: - Menu bar

struct MenuBarView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let hot = store.worktrees.filter { $0.state == "active" || $0.state == "review" }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Worktrees").font(F.ui(14, .bold))
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
            }
            .padding(12)
            Rectangle().fill(T.hairSoft).frame(height: 1)
            if hot.isEmpty {
                Text("Nothing active").foregroundStyle(T.muted).padding(12)
            }
            ForEach(hot.prefix(10)) { w in
                Button { store.openEditor(w) } label: {
                    HStack(spacing: 10) {
                        Glyph(state: w.state, size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(w.title).font(F.ui(13, .semibold))
                            Text(w.branchLabel).font(F.mono(11)).foregroundStyle(T.muted).lineLimit(1)
                        }
                        Spacer()
                        if w.dirty > 0 { Chip(text: "\(w.dirty)", tone: Tone(fg: T.amber, bg: T.amberSoft), radius: 6) }
                        if let pr = w.pr { Chip(text: "#" + String(pr.number), tone: prTone(pr).1, radius: 6) }
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .help("Open in \(Store.editor.label)")
            }
            Rectangle().fill(T.hairSoft).frame(height: 1)
            HStack {
                Button("Open Worktrees…") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(TButtonStyle(kind: .primary, height: 30))
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(TButtonStyle(height: 30))
            }
            .padding(12)
        }
        .font(F.ui(13))
        .foregroundStyle(T.fg)
        .frame(width: 340)
        .background(T.panel)
    }
}

// MARK: - Snapshot (`Worktrees --snapshot out.png [--select A,B] [--cleanup] [--group Repository] [--light]`)

enum Snapshot {
    static let args = CommandLine.arguments
    static var path: String? { value(after: "--snapshot") }
    static var select: String? { value(after: "--select") }
    static var group: String? { value(after: "--group") }
    static var cleanup: Bool { args.contains("--cleanup") }
    static var light: Bool { args.contains("--light") }
    private static var scheduled = false

    static func value(after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func schedule() {
        guard let path, !scheduled else { return }
        scheduled = true
        if let h = Double(value(after: "--height") ?? ""),
           let main = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) {
            main.setContentSize(NSSize(width: main.frame.width, height: h))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (Double(value(after: "--delay") ?? "") ?? 1.8)) {
            guard let main = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) else { exit(1) }
            let win = main.attachedSheet ?? main
            guard let view = win.contentView?.superview ?? win.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if Snapshot.light { NSApp.appearance = NSAppearance(named: .aqua) }
        if Snapshot.path == nil { NSApp.activate(ignoringOtherApps: true) }
        for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didEndLiveResizeNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                (note.object as? NSWindow).map(TrafficLights.place)
            }
        }
        DispatchQueue.main.async {
            NSApp.windows.forEach { w in
                w.isMovableByWindowBackground = true
                TrafficLights.place(w)
            }
        }
    }
}

/// The design puts the window buttons inside the floating sidebar panel (8pt inset + 14pt padding),
/// so the titlebar container is made 56pt tall and the buttons are centred in it.
enum TrafficLights {
    static func place(_ w: NSWindow) {
        guard w.frame.width > 600, !w.styleMask.contains(.fullScreen),
              let close = w.standardWindowButton(.closeButton),
              let titlebar = close.superview, let container = titlebar.superview else { return }
        let h: CGFloat = 56
        container.frame = NSRect(x: 0, y: w.frame.height - h, width: w.frame.width, height: h)
        titlebar.frame = container.bounds
        for (i, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let b = w.standardWindowButton(type) else { continue }
            b.setFrameOrigin(NSPoint(x: 22 + CGFloat(i) * 20, y: (h - b.frame.height) / 2))
        }
    }
}

@main
struct WorktreeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store()

    var body: some Scene {
        Window("Worktrees", id: "main") {
            MainView()
                .environmentObject(store)
                .frame(minWidth: 1120, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)

        MenuBarExtra {
            MenuBarView().environmentObject(store)
        } label: {
            Image(systemName: "arrow.triangle.branch")
        }
        .menuBarExtraStyle(.window)
    }
}
