import AppKit
import SwiftUI

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
