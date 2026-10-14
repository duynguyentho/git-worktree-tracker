import AppKit
import SwiftUI

@MainActor
final class Store: ObservableObject {
    @Published var data: Payload?
    @Published var loading = false
    @Published var busy: String?
    @Published var error: String?

    let script: String
    private var timer: Timer?
    private var procTimer: Timer?
    private var worklogTimer: Timer?
    private let systemSampler = SystemSampler()
    @Published var system: [SystemSample] = []
    @Published var worklog: WorklogPayload?
    @Published var pendingSelect: String?
    private var lastActivationScan = Date()
    var notify: Bool { UserDefaults.standard.object(forKey: "notify") as? Bool ?? true }
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
        if Self.fixture == nil && Snapshot.path == nil {
            Notifier.shared.setup()
            Notifier.shared.onOpen = { [weak self] path in self?.pendingSelect = path }
        }
        refreshWorklog()
        // Back from the terminal (where a file was just deleted, a commit pushed…): rescan for real.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, Date().timeIntervalSince(self.lastActivationScan) > 20 else { return }
                self.lastActivationScan = Date()
                self.refresh(force: true)
            }
        }
        worklogTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshWorklog() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(withSizes: true) }
        }
        procTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollProcesses() }
        }
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleLive() }
        }
    }

    var totalMemGB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }

    var running: [Worktree] { worktrees.filter { !$0.procs.isEmpty }.sorted { $0.rssKB > $1.rssKB } }

    /// Live RAM/CPU: `wt.py procs <paths>` (~0.3s) every 5s while the app is frontmost.
    private func synthesiseSystem() {
        let now = Date()
        system = (0..<Self.historyLength).map { i in
            let t = Double(i)
            return SystemSample(t: now.addingTimeInterval(Double(i - Self.historyLength)),
                                cpu: 28 + 14 * sin(t / 9) + 9 * sin(t / 2.7),
                                memGB: totalMemGB * (0.66 + 0.03 * sin(t / 30)),
                                rxBps: max(0, 900_000 + 700_000 * sin(t / 4) * sin(t / 13)),
                                txBps: max(0, 120_000 + 90_000 * sin(t / 5)))
        }
    }

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
            if system.isEmpty { synthesiseSystem() }
            return
        }
        if visible {
            system.append(systemSampler.sample())
            if system.count > Self.historyLength { system.removeFirst(system.count - Self.historyLength) }
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

    static let allWorkspaces = "__all__"
    @Published var workspace: String = UserDefaults.standard.string(forKey: "workspace") ?? Store.allWorkspaces {
        didSet { UserDefaults.standard.set(workspace, forKey: "workspace") }
    }

    var workspaces: [WorkspaceInfo] { data?.workspaces ?? [] }
    var multiWorkspace: Bool { workspaces.count > 1 }
    var currentWorkspace: WorkspaceInfo? { workspaces.first { $0.name == workspace } }
    /// The workspace that "Change folders…" edits: the selected one, else the first.
    var editableWorkspace: String { currentWorkspace?.name ?? workspaces.first?.name ?? "Default" }

    /// Worktrees of the selected workspace ("All" = every workspace).
    var worktrees: [Worktree] {
        let all = data?.worktrees ?? []
        guard currentWorkspace != nil else { return all }
        return all.filter { $0.workspace == workspace }
    }
    var shownBases: [String] { currentWorkspace?.bases ?? workspaces.flatMap(\.bases) }
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
            await load(["list", "--json"] + (force ? ["--refresh", "--fresh"] : []))
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
                    worklog = data?.worklog
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
            let next = try JSONDecoder().decode(Payload.self, from: raw)
            if !args.contains("--offline") { notifyTransitions(next) }
            data = next
            RepoStyle.config = data?.config?.repos ?? [:]
            error = nil
        } catch {
            self.error = "decode: \(error)"
        }
    }

    /// Compares each PR's state with the last one seen (persisted, so a restart never re-alerts)
    /// and posts a banner when a PR newly needs you — or got merged.
    private func notifyTransitions(_ next: Payload) {
        let key = "prStates"
        let first = UserDefaults.standard.dictionary(forKey: key) == nil
        var seen = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        for w in next.worktrees {
            guard let pr = w.pr else { continue }
            let state = pr.state == "MERGED" ? "MERGED" : (w.pr_status?.state ?? pr.state)
            let id = "\(w.repo)#\(pr.number)"
            let before = seen[id]
            seen[id] = state
            guard !first, notify, Snapshot.path == nil, Self.fixture == nil, let before, before != state else { continue }
            let title: String
            switch state {
            case "CHECKS_FAILED": title = "Checks failed"
            case "CONFLICTING": title = "Merge conflict"
            case "CHANGES_REQUESTED": title = "Changes requested"
            case "APPROVED": title = "Approved"
            case "MERGED": title = "Merged"
            default: continue
            }
            var body = "\(w.title) · PR #\(pr.number) — \(pr.title ?? w.branchLabel)"
            if let failed = w.pr_status?.failed_checks, state == "CHECKS_FAILED", !failed.isEmpty {
                body += "\nFailing: " + failed.joined(separator: ", ")
            }
            Notifier.shared.post(title: "\(title) — \(w.repo)", body: body, path: w.path, id: "\(id)-\(state)")
        }
        UserDefaults.standard.set(seen, forKey: key)
    }

    func refreshWorklog() {
        if Self.fixture != nil {
            worklog = data?.worklog
            return
        }
        Task {
            let (code, out, _) = await Shell.run("/usr/bin/python3", [script, "worklog"])
            guard code == 0, let raw = out.data(using: .utf8),
                  let w = try? JSONDecoder().decode(WorklogPayload.self, from: raw) else { return }
            worklog = w
        }
    }

    func loadRepos() async -> [RepoInfo] {
        if Self.fixture != nil {  // demo mode never touches the real machine
            return Array(Set(worktrees.map(\.repo))).sorted().map {
                RepoInfo(name: $0, path: "/Users/dev/Projects/acme/\($0)", kind: "normal", workspace: "Default",
                         default_base: "develop", bases: ["develop", "main"])
            }
        }
        let (code, out, _) = await Shell.run("/usr/bin/python3", [script, "repos"])
        guard code == 0, let raw = out.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([RepoInfo].self, from: raw)) ?? []
    }

    func createWorktree(repo: String, branch: String, base: String, cloneDeps: Bool) async -> CreateResult {
        let args = [script, "create", repo, branch, "--base", base, "--json"] + (cloneDeps ? [] : ["--no-deps"])
        let (_, out, err) = await Shell.run("/usr/bin/python3", args)
        if let raw = out.data(using: .utf8), let r = try? JSONDecoder().decode(CreateResult.self, from: raw) { return r }
        return CreateResult(ok: false, path: nil, branch: nil, base: nil, base_sha: nil,
                            error: err.isEmpty ? out : err, steps: nil, deps: nil)
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
    func jiraURL(for w: Worktree) -> String? {
        let ws = workspaces.first { $0.name == w.workspace }
        return (ws?.jira_url ?? data?.config?.jira_url).flatMap { $0.isEmpty ? nil : $0 }
    }
    func openJira(_ w: Worktree) {
        guard let key = w.ticket, let base = jiraURL(for: w) else { return }
        Shell.open(["\(base.hasSuffix("/") ? String(base.dropLast()) : base)/browse/\(key)"])
    }

    func remove(_ w: Worktree) { remove([w]) }

    func remove(_ ws: [Worktree]) {
        guard !ws.isEmpty, busy == nil else { return }
        // A blocker may be stale (untracked files are cached for 60 s): rescan before refusing.
        if ws.contains(where: { !$0.removable }), Self.fixture == nil {
            busy = "Re-checking…"
            Task {
                await load(["list", "--json", "--offline", "--fresh"])
                busy = nil
                let paths = Set(ws.map(\.path))
                decideRemoval(worktrees.filter { paths.contains($0.path) })
            }
            return
        }
        decideRemoval(ws)
    }

    private func decideRemoval(_ ws: [Worktree]) {
        guard !ws.isEmpty else { return }
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

    /// NSOpenPanel → `wt.py config --workspace W --set-bases …` → rescan.
    func chooseFolders(for ws: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Folders that hold your git repos"
        panel.message = "Repos up to 3 levels deep are found; their worktrees are discovered wherever they live."
        panel.prompt = "Use Folders"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.message = "Workspace “\(ws ?? editableWorkspace)”. " + panel.message
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        setBases(panel.urls.map(\.path), workspace: ws ?? editableWorkspace)
    }

    func setBases(_ paths: [String], workspace ws: String) {
        configure(["--workspace", ws, "--set-bases"] + paths)
    }

    func newWorkspace() {
        guard let name = Alerts.prompt("New workspace", "A name, e.g. Work or Personal. Then pick its folders.",
                                       placeholder: "Personal") else { return }
        chooseFolders(for: name)
        workspace = name
    }

    func renameWorkspace(_ ws: String) {
        guard let name = Alerts.prompt("Rename “\(ws)”", "", placeholder: ws), name != ws else { return }
        if workspace == ws { workspace = name }
        configure(["--workspace", ws, "--rename", name])
    }

    func removeWorkspace(_ ws: String) {
        guard Alerts.confirm("Remove workspace “\(ws)”?",
                             "Only the workspace is forgotten — no repo or worktree is touched.", button: "Remove") else { return }
        if workspace == ws { workspace = Self.allWorkspaces }
        configure(["--remove-workspace", ws])
    }

    private func configure(_ args: [String]) {
        busy = "Scanning…"
        Task {
            let (code, _, err) = await Shell.run("/usr/bin/python3", [script, "config"] + args)
            busy = nil
            if code != 0 { Alerts.info("Could not save the workspace", err) }
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
