import AppKit
import SwiftUI

enum Filter: Hashable {
    case all
    case running
    case attention
    case state(String)
    case repo(String)
}

enum GroupBy: String, CaseIterable { case status = "Status", repository = "Repository", recent = "Recent" }

struct ListGroup: Identifiable {
    let id: String
    let label: String
    let items: [Worktree]
}

struct MainView: View {
    @EnvironmentObject var store: Store
    @State private var filter: Filter = .all
    @State private var groupBy: GroupBy = .status
    @State private var selection: Set<String> = []
    @State private var anchor: String?
    @State private var query = ""
    @State private var showSidebar = true
    @State private var showCleanup = false
    @State private var showWelcome = false
    @State private var showNew = false
    @AppStorage("notify") private var notifyOn = true
    /// The detail panel only exists while something is selected, and can be closed even then.
    @AppStorage("detailClosed") private var detailClosed = false
    var showDetail: Bool { !selection.isEmpty && !detailClosed }
    @State private var welcomed = false
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    var filtered: [Worktree] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.worktrees.filter { w in
            switch filter {
            case .all: break
            case .running: if w.procs.isEmpty { return false }
            case .attention: if !w.attention { return false }
            case .state(let s): if w.state != s { return false }
            case .repo(let r): if w.repo != r { return false }
            }
            guard !q.isEmpty else { return true }
            return [w.name, w.branch ?? "", w.ticket ?? "", w.repo].contains { $0.lowercased().contains(q) }
        }
    }

    var groups: [ListGroup] {
        let items = filtered
        switch groupBy {
        case .status:
            return stateOrder.compactMap { s in
                let g = items.filter { $0.state == s }
                return g.isEmpty ? nil : ListGroup(id: s, label: StateStyle.of(s).title, items: g)
            }
        case .repository:
            return Dictionary(grouping: items, by: \.repo)
                .sorted { $0.value.count > $1.value.count }
                .map { ListGroup(id: $0.key, label: $0.key,
                                 items: $0.value.sorted { ($0.git.activity_ts ?? 0) > ($1.git.activity_ts ?? 0) }) }
        case .recent:
            let now = Date().timeIntervalSince1970
            let sorted = items.sorted { ($0.git.activity_ts ?? 0) > ($1.git.activity_ts ?? 0) }
            let buckets: [(String, (Double) -> Bool)] = [
                ("Today", { $0 < 86400 }), ("This week", { $0 >= 86400 && $0 < 7 * 86400 }), ("Older", { $0 >= 7 * 86400 }),
            ]
            return buckets.compactMap { label, test in
                let g = sorted.filter { test(now - Double($0.git.activity_ts ?? 0)) }
                return g.isEmpty ? nil : ListGroup(id: label, label: label, items: g)
            }
        }
    }

    var flat: [Worktree] { groups.flatMap(\.items) }
    var selected: [Worktree] { store.worktrees.filter { selection.contains($0.path) } }

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                SidebarView(filter: $filter, showCleanup: $showCleanup) { withAnimation(.snappy) { showSidebar = false } }
                    .frame(width: 248)
                    .padding(8)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(spacing: 0) {
                toolbar
                HStack(alignment: .top, spacing: 8) {
                    listPanel.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                    if showDetail {
                        detailPanel.frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.leading, showSidebar ? 0 : 8)
                .padding([.trailing, .bottom], 8)
                .animation(.snappy, value: showDetail)
                .overlay(alignment: .bottom) {
                    if let err = store.error {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(F.ui(12)).lineLimit(3)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(T.dangerSoft))
                            .foregroundStyle(T.danger)
                            .padding()
                    }
                }
            }
        }
        .background(T.bg)
        .ignoresSafeArea()
        .font(F.ui(13))
        .foregroundStyle(T.fg)
        .sheet(isPresented: $showCleanup) { CleanupSheet().environmentObject(store) }
        .sheet(isPresented: $showWelcome) { WelcomeSheet().environmentObject(store) }
        .sheet(isPresented: $showNew) {
            NewWorktreeSheet(preferredRepo: selected.first?.repo_path).environmentObject(store)
        }
        .onChange(of: store.pendingSelect) {
            guard let p = store.pendingSelect else { return }
            if store.worktrees.contains(where: { $0.path == p }) {
                selection = [p]
                anchor = p
                store.pendingSelect = nil
            }
        }
        .onChange(of: store.data?.generated_at) {
            if let p = store.pendingSelect, store.worktrees.contains(where: { $0.path == p }) {
                selection = [p]
                anchor = p
                store.pendingSelect = nil
            }
        }
        .onAppear { DispatchQueue.main.async { listFocused = true } }
        .background(shortcuts)
        .onChange(of: store.data?.generated_at) {
            if !welcomed, store.data?.configured == false, Store.fixture == nil, Snapshot.path == nil || Snapshot.args.contains("--welcome") {
                welcomed = true
                showWelcome = true
            }
            selection = selection.intersection(Set(store.worktrees.map(\.path)))
            if Snapshot.select != nil { detailClosed = false }
            if selection.isEmpty, let ids = Snapshot.select {
                selection = Set(ids.split(separator: ",").compactMap { id in
                    store.worktrees.first { $0.name.localizedCaseInsensitiveContains(String(id)) }?.path
                })
            }
            if Snapshot.cleanup { showCleanup = true }
            if Snapshot.args.contains("--new") { showNew = true }
            if let g = Snapshot.group, let v = GroupBy(rawValue: g) { groupBy = v }
            Snapshot.schedule()
        }
    }

    var shortcuts: some View {
        ZStack {
            Button("") { searchFocused = true }.keyboardShortcut("k")
            Button("") { showNew = true }.keyboardShortcut("n")
            Button("") { withAnimation(.snappy) { detailClosed.toggle() } }.keyboardShortcut("d", modifiers: [.command, .option])
            Button("") { store.refresh(withSizes: true, force: true) }.keyboardShortcut("r")
            Button("") { selection = Set(flat.map(\.path)) }.keyboardShortcut("a").disabled(searchFocused)
            Button("") { store.remove(selected) }.keyboardShortcut(.delete, modifiers: .command).disabled(searchFocused)
            Button("") { withAnimation(.snappy) { showSidebar.toggle() } }.keyboardShortcut("s", modifiers: [.command, .control])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    // Toolbar

    var subtitle: String {
        guard let d = store.data else { return "Loading…" }
        _ = d
        return (["\(store.worktrees.count) worktrees"]
            + [("active", "active"), ("review", "in review"), ("merged", "merged")]
                .compactMap { store.count($0.0) > 0 ? "\(store.count($0.0)) \($0.1)" : nil })
            .joined(separator: " · ")
    }

    var toolbar: some View {
        HStack(spacing: 12) {
            if !showSidebar {
                Color.clear.frame(width: 64)
                Button { withAnimation(.snappy) { showSidebar = true } } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 14))
                }
                .buttonStyle(TButtonStyle(height: 32, square: true))
                .help("Show sidebar ⌃⌘S")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Worktrees").font(F.ui(15, .bold)).tracking(-0.15)
                Text(subtitle).font(F.ui(12)).foregroundStyle(T.muted).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if store.loading || store.busy != nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(store.busy ?? "Refreshing…").font(F.ui(12)).foregroundStyle(T.muted)
                }
            }
            Button { showNew = true } label: {
                Label("New", systemImage: "plus").labelStyle(GapLabel())
            }
            .buttonStyle(TButtonStyle(kind: .primary, height: 34))
            .help("New worktree from a ticket ⌘N")
            SegmentedControl(value: $groupBy)
            editorMenu
            Button { notifyOn.toggle() } label: {
                Image(systemName: notifyOn ? "bell.fill" : "bell.slash").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(TButtonStyle(height: 34, square: true))
            .help(notifyOn ? "Notifications on: checks failed, conflict, changes requested, approved, merged" : "Notifications off")
            Button { withAnimation(.snappy) { detailClosed.toggle() } } label: {
                Image(systemName: "sidebar.right").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(showDetail ? T.accentText : T.fg)
            }
            .buttonStyle(TButtonStyle(height: 34, square: true))
            .disabled(selection.isEmpty)
            .help(showDetail ? "Hide details ⌥⌘D" : "Show details ⌥⌘D")
            Button { store.refresh(withSizes: true, force: true) } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(TButtonStyle(height: 34, square: true))
            .help("Refresh ⌘R")
            searchField
        }
        .padding(.leading, 12).padding(.trailing, 16)
        .padding(.top, 14).padding(.bottom, 12)
        .frame(minHeight: 52)
    }

    var editorMenu: some View {
        Menu {
            ForEach(editors, id: \.id) { e in
                Button {
                    UserDefaults.standard.set(e.id, forKey: "editor")
                    store.objectWillChange.send()
                } label: {
                    if Store.editor.id == e.id { Label(e.label, systemImage: "checkmark") } else { Text(e.label) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 11, weight: .semibold))
                Text(Store.editor.label).font(F.ui(12, .medium))
            }
            .foregroundStyle(T.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.control))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(T.hair))
        .help("Editor used by Open")
    }

    var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(T.subtle)
            TextField("Ticket, branch, repo…", text: $query)
                .textFieldStyle(.plain)
                .font(F.ui(13))
                .focused($searchFocused)
                .onSubmit { listFocused = true }
                .onExitCommand { query = ""; searchFocused = false }
            if query.isEmpty {
                Text("⌘K").font(F.ui(11, .medium)).foregroundStyle(T.muted)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(T.well))
            } else {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(T.subtle) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.leading, 12).padding(.trailing, 10)
        .frame(minWidth: 180, idealWidth: 300, maxWidth: 300)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.control))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(searchFocused ? T.accentBorder : T.hair, lineWidth: searchFocused ? 1.5 : 1))
    }

    // List

    var listPanel: some View {
        Group {
            if store.data == nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Scanning worktrees…").foregroundStyle(T.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 26)).foregroundStyle(T.faint)
                    Text(query.isEmpty ? "No worktrees found" : "No match for “\(query)”").font(F.ui(14, .semibold))
                    if query.isEmpty {
                        Text("Scanning " + store.shownBases.map(tildePath).joined(separator: ", "))
                            .font(F.ui(12)).foregroundStyle(T.muted).multilineTextAlignment(.center)
                        Button("Choose folders…") { store.chooseFolders() }.buttonStyle(TButtonStyle(height: 30))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(groups) { g in
                                HStack(spacing: 8) {
                                    Text(g.label)
                                    Text("\(g.items.count)").monospacedDigit()
                                        .foregroundStyle(T.muted)
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Capsule().fill(T.well))
                                }
                                .font(F.ui(11, .semibold))
                                .foregroundStyle(T.subtle)
                                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
                                ForEach(g.items) { w in
                                    RowView(w: w, isSelected: selection.contains(w.path), selectionCount: selection.count,
                                            selectedItems: { selected })
                                        .id(w.path)
                                        .onTapGesture { click(w) }
                                }
                                Color.clear.frame(height: 6)
                            }
                        }
                        .padding(6)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: anchor) { if let a = anchor { proxy.scrollTo(a) } }
                }
            }
        }
        .panel()
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            store.remove(selected)
            return .handled
        }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            move(press.key == .upArrow ? -1 : 1, extend: press.modifiers.contains(.shift))
            return .handled
        }
        .onKeyPress(.escape) {
            guard !selection.isEmpty else { return .ignored }
            withAnimation(.snappy) { selection = [] }
            return .handled
        }
        .onKeyPress(.return) {
            selected.prefix(3).forEach(store.openEditor)
            return .handled
        }
    }

    func click(_ w: Worktree) {
        listFocused = true
        if NSApp.currentEvent?.clickCount == 2 {
            store.openEditor(w)
            return
        }
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selection.contains(w.path) { selection.remove(w.path) } else { selection.insert(w.path) }
            anchor = w.path
        } else if mods.contains(.shift), let a = anchor,
                  let i = flat.firstIndex(where: { $0.path == a }), let j = flat.firstIndex(where: { $0.path == w.path }) {
            selection = Set(flat[min(i, j)...max(i, j)].map(\.path))
        } else {
            if detailClosed { withAnimation(.snappy) { detailClosed = false } }
            selection = [w.path]
            anchor = w.path
        }
    }

    func move(_ delta: Int, extend: Bool) {
        let list = flat
        guard !list.isEmpty else { return }
        let cur = anchor.flatMap { a in list.firstIndex { $0.path == a } } ?? (delta > 0 ? -1 : list.count)
        let next = min(max(cur + delta, 0), list.count - 1)
        let path = list[next].path
        if extend { selection.insert(path) } else { selection = [path] }
        anchor = path
    }

    // Detail

    var detailPanel: some View {
        Group {
            let sel = selected
            if sel.count == 1 {
                DetailView(w: sel[0])
            } else if sel.count > 1 {
                MultiSelectView(items: sel)
            }
        }
        .panel()
        .overlay(alignment: .topTrailing) {
            Button { withAnimation(.snappy) { detailClosed = true } } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(T.subtle)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(T.well))
            }
            .buttonStyle(.plain)
            .padding(12)
            .help("Close the panel (Esc clears the selection, ⌥⌘D toggles)")
        }
    }
}
