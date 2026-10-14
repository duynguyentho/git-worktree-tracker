import AppKit
import SwiftUI

struct RunningCard: View {
    @EnvironmentObject var store: Store
    let showAll: () -> Void

    var body: some View {
        let run = store.running
        let kb = run.reduce(0) { $0 + $1.rssKB }
        let cpu = run.reduce(0) { $0 + $1.cpu }

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Running").font(F.ui(12, .semibold))
                LiveDot(compact: true).help("Live · sampled every second")
                Spacer()
                Text("\(memText(kb)) · \(cpuText(cpu))").font(F.ui(12)).monospacedDigit().foregroundStyle(T.danger)
                    .lineLimit(1).fixedSize()
            }
            ForEach(run.prefix(4)) { w in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(w.title).font(F.ui(12, .medium)).lineLimit(1)
                        Spacer()
                        Text(w.usage).font(F.ui(11.5)).monospacedDigit().foregroundStyle(T.muted)
                    }
                    Sparkline(values: (store.history[w.path] ?? []).map(\.cpu), color: T.accentText,
                              ceiling: max(100, (store.history[w.path] ?? []).map(\.cpu).max() ?? 0))
                        .frame(height: 18)
                        .help("CPU, last 2 minutes")
                }
            }
            if run.count > 4 {
                Button("+ \(run.count - 4) more", action: showAll).buttonStyle(.plain).font(F.ui(11.5)).foregroundStyle(T.accentText)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(dyn(oklch(1, 0, 0, 0.7), oklch(0.16, 0.008, 250, 0.6))))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(T.hairSoft))
        .contentShape(Rectangle())
        .onTapGesture(perform: showAll)
        .help("Show only worktrees with running processes")
    }
}
