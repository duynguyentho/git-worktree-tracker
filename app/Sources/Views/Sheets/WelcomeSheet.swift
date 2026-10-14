import AppKit
import SwiftUI

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
                    Button("Use these") { store.setBases(bases, workspace: store.editableWorkspace); dismiss() }
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
