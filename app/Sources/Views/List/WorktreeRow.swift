import AppKit
import SwiftUI

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
                    if store.multiWorkspace, store.currentWorkspace == nil, let ws = w.workspace {
                        Chip(text: ws, tone: Tone(fg: T.muted, bg: T.well), radius: 6).fixedSize()
                    }
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
        if let t = w.ticket, store.jiraURL(for: w) != nil { Button("Open \(t) in Jira") { store.openJira(w) } }
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
