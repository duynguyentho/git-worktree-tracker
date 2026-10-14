import AppKit
import SwiftUI

struct Payload: Decodable {
    let generated_at: Int
    let disk: Disk
    let totals: Totals
    var worktrees: [Worktree]
    let config: AppConfig?
    let bases: [String]?
    let configured: Bool?
    let workspaces: [WorkspaceInfo]?
    let worklog: WorklogPayload?
}

struct WorklogPayload: Decodable {
    let available: Bool
    let band: [Int]?
    let target: Int?
    let day: WorklogDay?
    let error: String?
    let at: Int?
}

struct WorklogDay: Decodable {
    let date: String
    let total_seconds: Int
    let total: String
    let state: String
    let entries: [WorklogEntry]
}

struct WorklogEntry: Decodable, Hashable {
    let id: String?
    let key: String
    let summary: String?
    let seconds: Int
    let timeSpent: String
    let started: String
    let comment: String?
}

struct RepoInfo: Decodable, Hashable {
    let name: String
    let path: String
    let kind: String
    let workspace: String
    let default_base: String
    let bases: [String]
}

struct CreateResult: Decodable {
    let ok: Bool
    let path: String?
    let branch: String?
    let base: String?
    let base_sha: String?
    let error: String?
    let steps: [String]?
    let deps: [DepResult]?
}

struct DepResult: Decodable, Hashable { let dir: String; let cloned: Bool; let seconds: Double?; let reason: String? }

struct WorkspaceInfo: Decodable, Hashable {
    let name: String
    let bases: [String]
    let jira_url: String?
    let configured: Bool
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
