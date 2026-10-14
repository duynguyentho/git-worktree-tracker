import AppKit
import SwiftUI

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
