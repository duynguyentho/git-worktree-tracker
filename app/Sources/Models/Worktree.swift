import AppKit
import SwiftUI

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
    let workspace: String?
    let repo_kind: String?
    let repo_path: String?
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

let stateOrder = ["active", "review", "idle", "stale", "merged", "closed", "missing"]

let prunable: Set<String> = ["merged", "closed", "missing"]
