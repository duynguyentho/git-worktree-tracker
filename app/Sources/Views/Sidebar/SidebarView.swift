import AppKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: Store
    @Binding var filter: Filter
    @Binding var showCleanup: Bool
    let hide: () -> Void

    var repos: [(String, Int)] {
        Dictionary(grouping: store.worktrees, by: \.repo).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Spacer()
                Button(action: hide) { Image(systemName: "sidebar.left").font(.system(size: 14)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(T.muted)
                    .frame(width: 28, height: 28)
                    .help("Hide sidebar ⌃⌘S")
            }
            .frame(height: 28)
            .padding(.horizontal, 6)

            // One scroll area: the cards sit at the bottom when everything fits and scroll with the
            // navigation when the window is too short.
            GeometryReader { geo in
            ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
            nav("Status") {
                NavRow(icon: "square.stack.3d.up.fill", tint: T.accentText, label: "All worktrees",
                       count: store.worktrees.count, on: filter == .all) { filter = .all }
                ForEach(stateOrder.filter { store.count($0) > 0 }, id: \.self) { s in
                    let st = StateStyle.of(s)
                    NavRow(icon: st.symbol, tint: st.tone.fg, label: st.title, count: store.count(s),
                           on: filter == .state(s)) { filter = filter == .state(s) ? .all : .state(s) }
                }
                let attn = store.worktrees.filter(\.attention).count
                if attn > 0 {
                    NavRow(icon: "exclamationmark.triangle.fill", tint: T.danger, label: "Needs attention", count: attn,
                           on: filter == .attention) { filter = filter == .attention ? .all : .attention }
                }
                NavRow(icon: "gauge.with.dots.needle.67percent", tint: T.danger, label: "Running", count: store.running.count,
                       on: filter == .running) { filter = filter == .running ? .all : .running }
            }
            nav("Repositories") {
                ForEach(repos, id: \.0) { repo, n in
                    NavRow(dot: RepoStyle.of(repo).dot, label: repo, count: n,
                           on: filter == .repo(repo)) { filter = filter == .repo(repo) ? .all : .repo(repo) }
                }
            }
            nav(store.multiWorkspace ? "Workspace" : "Folders") {
                if store.multiWorkspace || store.workspaces.first?.configured == true {
                    WorkspaceSwitcher()
                }
                ForEach(store.shownBases, id: \.self) { b in
                    HStack(spacing: 10) {
                        Image(systemName: "folder").font(.system(size: 12, weight: .semibold)).foregroundStyle(T.muted).frame(width: 16)
                        Text(tildePath(b)).font(F.ui(12.5)).foregroundStyle(T.muted).lineLimit(1).truncationMode(.head)
                    }
                    .padding(.horizontal, 10).frame(height: 24)
                    .help(b)
                }
                Button { store.chooseFolders() } label: {
                    Label("Change folders…", systemImage: "folder.badge.gearshape").font(F.ui(12.5, .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(T.accentText)
                .padding(.horizontal, 10).frame(height: 26)
                .help("Folders of “\(store.editableWorkspace)”")
            }
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                if !store.running.isEmpty { RunningCard { filter = .running } }
                if store.worklog?.available == true { WorklogCard() }
                if store.data != nil { ThisMacCard(showCleanup: $showCleanup) }
            }
            }
            .frame(minHeight: geo.size.height, alignment: .top)
            }
            .scrollIndicators(.never)
            }
        }
        .padding(EdgeInsets(top: 6, leading: 10, bottom: 10, trailing: 10))
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(T.sidebar))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(T.hair))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 10)
    }

    func nav<C: View>(_ title: String, @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(F.ui(11, .semibold)).tracking(0.2).foregroundStyle(T.subtle)
                .padding(.horizontal, 10).padding(.bottom, 6)
            rows()
        }
    }
}

struct WorkspaceSwitcher: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let all = store.data?.worktrees ?? []
        Menu {
            Button {
                store.workspace = Store.allWorkspaces
            } label: {
                Label("All workspaces (\(all.count))", systemImage: store.currentWorkspace == nil ? "checkmark" : "square.stack.3d.up")
            }
            Divider()
            ForEach(store.workspaces, id: \.name) { ws in
                Button { store.workspace = ws.name } label: {
                    let n = all.filter { $0.workspace == ws.name }.count
                    Label("\(ws.name) (\(n))", systemImage: store.workspace == ws.name ? "checkmark" : "folder")
                }
            }
            Divider()
            Button("New workspace…") { store.newWorkspace() }
            if let ws = store.currentWorkspace {
                Button("Rename “\(ws.name)”…") { store.renameWorkspace(ws.name) }
                if store.multiWorkspace {
                    Button("Remove “\(ws.name)”…", role: .destructive) { store.removeWorkspace(ws.name) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(T.accentText)
                Text(store.currentWorkspace?.name ?? (store.multiWorkspace ? "All workspaces" : store.workspaces.first?.name ?? "Workspace"))
                    .font(F.ui(13, .semibold)).foregroundStyle(T.fg).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(T.subtle)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.navOn))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

struct NavRow: View {
    var icon: String? = nil
    var tint: Color = T.muted
    var dot: Color? = nil
    let label: String
    let count: Int
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint).frame(width: 16)
                } else if let dot {
                    RoundedRectangle(cornerRadius: 3).fill(dot).frame(width: 10, height: 10).frame(width: 16)
                }
                Text(label).font(F.ui(13, on ? .semibold : .medium)).foregroundStyle(T.fg).lineLimit(1)
                Spacer()
                Text("\(count)").font(F.ui(12)).monospacedDigit().foregroundStyle(T.muted)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? T.navOn : hover ? T.navHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
