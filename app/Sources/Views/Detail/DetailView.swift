import AppKit
import SwiftUI

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
                    if w.repo_kind == "bare" { Chip(text: "bare repo", tone: Tone(fg: T.muted, bg: T.well)) }
                    if store.multiWorkspace, let ws = w.workspace { Chip(text: ws, tone: Tone(fg: T.muted, bg: T.well)) }
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
            if w.ticket != nil, store.jiraURL(for: w) != nil {
                Button { store.openJira(w) } label: { Label("Jira", systemImage: "arrow.up.forward.square") }
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
                    Button { store.remove(w) } label: {
                        Label(w.removable ? "Remove worktree" : "Re-check & remove", systemImage: "trash")
                    }
                    .buttonStyle(TButtonStyle(kind: .danger, height: 34))
                    .labelStyle(GapLabel())
                    .disabled(store.busy != nil)
                    .help(w.removable ? "Remove this worktree" : "Rescans the worktree first — removes it if nothing blocks any more")
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
