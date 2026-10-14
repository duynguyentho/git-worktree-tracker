import AppKit
import SwiftUI

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
