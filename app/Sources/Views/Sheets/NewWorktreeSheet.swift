import AppKit
import SwiftUI

struct NewWorktreeSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let preferredRepo: String?
    @State private var repos: [RepoInfo] = []
    @State private var repoPath = ""
    @State private var ticket = ""
    @State private var kind = "feat"
    @State private var branch = ""
    @State private var branchEdited = false
    @State private var base = ""
    @State private var cloneDeps = true
    @State private var openAfter = true
    @State private var running = false
    @State private var result: CreateResult?

    var repo: RepoInfo? { repos.first { $0.path == repoPath } }
    var suggested: String {
        let key = ticket.trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? "" : "\(kind)/\(key)"
    }
    var folder: String {
        guard let r = repo else { return "" }
        let parent = (r.path as NSString).deletingLastPathComponent
        let safe = branch.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
        return tildePath("\(r.kind == "bare" ? (parent as NSString).deletingLastPathComponent : parent)/worktrees/\(r.name)-\(safe)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "plus.rectangle.on.folder").font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(T.accentText)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(T.accentSoft))
                VStack(alignment: .leading, spacing: 4) {
                    Text("New worktree").font(F.ui(18, .bold))
                    Text("A new branch off a freshly fetched base, in a sibling worktrees/ folder. If the base cannot be fetched, nothing is created.")
                        .font(F.ui(12.5)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    label("Repository")
                    Picker("", selection: $repoPath) {
                        ForEach(repos, id: \.path) { r in
                            let dup = repos.filter { $0.name == r.name }.count > 1
                            let place = dup ? "  —  " + tildePath((r.path as NSString).deletingLastPathComponent) : ""
                            Text((store.multiWorkspace ? "\(r.name)  ·  \(r.workspace)" : r.name) + place).tag(r.path)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    label("Ticket")
                    TextField("ABC-123 (optional)", text: $ticket).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    label("Type")
                    Picker("", selection: $kind) {
                        ForEach(["feat", "fix", "chore"], id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
                GridRow {
                    label("Branch")
                    TextField("feat/ABC-123", text: Binding(get: { branch }, set: { branch = $0; branchEdited = true }))
                        .textFieldStyle(.roundedBorder).font(F.mono(12.5))
                }
                GridRow {
                    label("Base")
                    HStack(spacing: 6) {
                        TextField("develop", text: $base).textFieldStyle(.roundedBorder).font(F.mono(12.5))
                        Menu {
                            ForEach(repo?.bases ?? [], id: \.self) { b in Button(b) { base = b } }
                        } label: { Image(systemName: "chevron.down") }
                        .menuIndicator(.hidden).fixedSize()
                    }
                }
                GridRow {
                    label("Folder")
                    Text(folder).font(F.mono(11.5)).foregroundStyle(T.muted).lineLimit(2).truncationMode(.head)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Clone node_modules from the main checkout when the lockfile matches (APFS copy-on-write)", isOn: $cloneDeps)
                Toggle("Open in \(Store.editor.label) when done", isOn: $openAfter)
            }
            .toggleStyle(.checkbox).font(F.ui(12.5))
            if let r = result {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(r.steps ?? [], id: \.self) { st in
                        Label(st, systemImage: "checkmark.circle.fill").foregroundStyle(T.green)
                    }
                    ForEach((r.deps ?? []).filter { !$0.cloned }, id: \.self) { d in
                        Label("\(d.dir): \(d.reason ?? "not cloned")", systemImage: "exclamationmark.circle.fill").foregroundStyle(T.amber)
                    }
                    if let e = r.error { Label(e, systemImage: "xmark.octagon.fill").foregroundStyle(T.danger) }
                }
                .font(F.ui(12)).lineLimit(3)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(T.section))
            }
            HStack {
                if running {
                    ProgressView().controlSize(.small)
                    Text("Fetching origin/\(base) and creating…").font(F.ui(12)).foregroundStyle(T.muted)
                }
                Spacer()
                Button(result?.ok == true ? "Done" : "Cancel") { dismiss() }
                    .buttonStyle(TButtonStyle())
                    .keyboardShortcut(.cancelAction)
                if result?.ok != true {
                    Button("Create worktree") { create() }
                        .buttonStyle(TButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(running || repo == nil || branch.isEmpty || base.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 600)
        .background(T.sheet)
        .font(F.ui(13))
        .foregroundStyle(T.fg)
        .task {
            // Most-used repos first: the one with the most worktrees is almost always the one you mean.
            let uses = Dictionary(grouping: store.worktrees.compactMap(\.repo_path), by: { $0 }).mapValues(\.count)
            repos = await store.loadRepos()
                .filter { store.currentWorkspace == nil || $0.workspace == store.workspace }
                .sorted { (uses[$0.path] ?? 0, $1.name) > (uses[$1.path] ?? 0, $0.name) }
            repoPath = repos.first { $0.path == preferredRepo }?.path ?? repos.first?.path ?? ""
            base = repo?.default_base ?? ""
        }
        .onChange(of: repoPath) { base = repo?.default_base ?? base }
        .onChange(of: ticket) { if !branchEdited { branch = suggested } }
        .onChange(of: kind) { if !branchEdited { branch = suggested } }
    }

    func label(_ t: String) -> some View {
        Text(t).font(F.ui(12.5)).foregroundStyle(T.subtle).gridColumnAlignment(.trailing)
    }

    func create() {
        guard let r = repo else { return }
        running = true
        result = nil
        Task {
            let res = await store.createWorktree(repo: r.path, branch: branch, base: base, cloneDeps: cloneDeps)
            running = false
            result = res
            if res.ok, let path = res.path {
                if openAfter { Shell.open(["-b", Store.editor.app, path]) }
                store.pendingSelect = path
                store.refresh(withSizes: true)
            }
        }
    }
}
