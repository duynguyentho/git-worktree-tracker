import AppKit
import SwiftUI

struct CleanupSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var checked: Set<String> = []
    @State private var deleteBranches = false
    @State private var initialized = false

    var candidates: [Worktree] {
        store.cleanupCandidates.sorted {
            ($0.removable ? 1 : 0, -($0.git.activity_ts ?? 0)) < ($1.removable ? 1 : 0, -($1.git.activity_ts ?? 0))
        }
    }

    var body: some View {
        let cands = candidates
        let removable = cands.filter(\.removable)
        let picked = cands.filter { checked.contains($0.path) && ($0.removable || $0.forceRemovable) }
        let forced = picked.filter { !$0.removable }
        let gb = picked.reduce(0) { $0 + $1.gb }

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "sparkles").font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(T.amber)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(T.amberSoft))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Clean up merged worktrees").font(F.ui(18, .bold)).tracking(-0.18)
                    Text("\(plural(cands.count, "worktree")) \(cands.count == 1 ? "has" : "have") a merged or closed PR. Removing one deletes its folder and its dependency/build folders — the branch stays on origin. Tick an amber row to force it: its changes are backed up first.")
                        .font(F.ui(13)).foregroundStyle(T.muted).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(EdgeInsets(top: 24, leading: 24, bottom: 16, trailing: 24))

            HStack(spacing: 8) {
                Tile(label: "Selected", value: "\(picked.count)", big: 20)
                Tile(label: "Frees", value: gbText(gb), tint: T.amber, big: 20)
                Tile(label: "Need review", value: "\(cands.count - removable.count)", big: 20)
            }
            .padding(.horizontal, 24).padding(.bottom, 16)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Toggle(isOn: Binding(
                        get: { !removable.isEmpty && removable.allSatisfy { checked.contains($0.path) } },
                        set: { on in checked = on ? Set(removable.map(\.path)) : [] })) { EmptyView() }
                        .toggleStyle(.checkbox).labelsHidden()
                    Text("Worktree").frame(maxWidth: .infinity, alignment: .leading)
                    Text("PR").frame(width: 80, alignment: .leading)
                    Text("Size").frame(width: 64, alignment: .trailing)
                }
                .font(F.ui(11.5, .semibold))
                .foregroundStyle(T.subtle)
                .padding(.horizontal, 14).padding(.vertical, 10)
                Rectangle().fill(T.hairSoft).frame(height: 1)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(cands.enumerated()), id: \.element.path) { i, w in
                            if i > 0 { Rectangle().fill(T.hairSoft).frame(height: 1) }
                            cleanupRow(w)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(dyn(oklch(0.985, 0.003, 250), oklch(0.17, 0.008, 250))))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(T.hairSoft))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 24)

            HStack(spacing: 10) {
                Toggle(isOn: $deleteBranches) {
                    Text("Also delete local branches").font(F.ui(12.5)).foregroundStyle(T.muted)
                }
                .toggleStyle(.checkbox)
                .help("Deletes a branch only when git agrees it is merged, or its tip is exactly the merged PR head")
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(TButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Remove \(plural(picked.count, "worktree"))" + (forced.isEmpty ? "" : " · \(forced.count) forced")) {
                    guard store.confirmForce(forced) else { return }
                    store.removeConfirmed(picked, deleteBranches: deleteBranches, force: !forced.isEmpty)
                    dismiss()
                }
                .buttonStyle(TButtonStyle(kind: forced.isEmpty ? .primary : .danger))
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty || store.busy != nil)
            }
            .padding(EdgeInsets(top: 16, leading: 24, bottom: 20, trailing: 24))
        }
        .frame(width: 720, height: 660)
        .background(T.sheet)
        .font(F.ui(13))
        .foregroundStyle(T.fg)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            checked = Set(removable.map(\.path))
        }
    }

    func cleanupRow(_ w: Worktree) -> some View {
        let blocked = !w.removable
        let checkable = w.removable || w.forceRemovable
        let forcing = blocked && checked.contains(w.path)
        return HStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { checked.contains(w.path) },
                set: { on in if on { checked.insert(w.path) } else { checked.remove(w.path) } })) { EmptyView() }
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(!checkable)
                .help(checkable ? (blocked ? "Tick to force remove — changes are backed up first" : "")
                      : "Can't be forced: " + (w.force_blockers ?? []).joined(separator: "; "))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(w.title).font(F.ui(13, .semibold))
                    if forcing {
                        Chip(text: "force · backup", tone: Tone(fg: T.danger, bg: T.dangerSoft), radius: 6)
                    }
                    if blocked {
                        Text("· " + w.remove_blockers.joined(separator: " · ")).font(F.ui(12, .medium))
                            .foregroundStyle(checkable ? T.amber : T.danger).lineLimit(1)
                    }
                }
                Text(w.branchLabel).font(F.mono(11.5)).foregroundStyle(T.muted).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(w.pr.map { "#" + String($0.number) } ?? "—").font(F.ui(12, .semibold))
                .foregroundStyle(w.pr != nil ? T.purple : T.subtle)
                .frame(width: 80, alignment: .leading)
            Text(w.artifacts.kind == "dir" ? sizeText(w.artifacts) : "—").monospacedDigit().foregroundStyle(T.muted)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(forcing ? T.dangerSoft : blocked ? T.amberRow : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            guard checkable else { return }
            if checked.contains(w.path) { checked.remove(w.path) } else { checked.insert(w.path) }
        }
    }
}
