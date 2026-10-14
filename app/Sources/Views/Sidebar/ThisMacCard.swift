import AppKit
import SwiftUI

struct ThisMacCard: View {
    @EnvironmentObject var store: Store
    @Binding var showCleanup: Bool

    var body: some View {
        let d = store.data!
        let total = max(d.disk.total_gb, 1)
        let used = total - d.disk.free_gb
        let nm = store.worktrees.reduce(0) { $0 + $1.gb }
        let reclaim = store.pruneCandidates.reduce(0) { $0 + $1.gb }
        let cands = store.cleanupCandidates.count

        let sys = store.system
        let last = sys.last
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("This Mac").font(F.ui(12, .semibold))
                LiveDot(compact: true)
                Spacer()
            }
            VStack(spacing: 7) {
                sysRow("CPU", last.map { cpuText($0.cpu) } ?? "—", sys.map(\.cpu), T.accentText, ceiling: 100)
                    .help("Whole machine: 100% = every core busy")
                sysRow("Memory", last.map { String(format: "%.1f/%.0f GB", $0.memGB, store.totalMemGB) } ?? "—",
                       sys.map(\.memGB), T.danger, ceiling: store.totalMemGB)
                    .help("App memory + wired + compressed, as in Activity Monitor")
                HStack(spacing: 8) {
                    Text("Network").foregroundStyle(T.muted).frame(width: 54, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("↓ " + (last.map { rateText($0.rxBps) } ?? "—")).foregroundStyle(T.green)
                        Text("↑ " + (last.map { rateText($0.txBps) } ?? "—")).foregroundStyle(T.blue)
                    }
                    .font(F.ui(11)).monospacedDigit().lineLimit(1).fixedSize()
                    Spacer(minLength: 4)
                    ZStack {
                        Sparkline(values: sys.map(\.rxBps), color: T.green, ceiling: max(1, sys.map { max($0.rxBps, $0.txBps) }.max() ?? 1), stretch: true)
                        Sparkline(values: sys.map(\.txBps), color: T.blue, ceiling: max(1, sys.map { max($0.rxBps, $0.txBps) }.max() ?? 1), stretch: true)
                    }
                    .frame(height: 18).frame(minWidth: 30)
                }
                .font(F.ui(12))
            }
            Rectangle().fill(T.hairSoft).frame(height: 1)
            HStack(alignment: .firstTextBaseline) {
                Text("Disk").font(F.ui(12, .semibold))
                Spacer()
                Text("\(Int(d.disk.free_gb)) GB free of \(Int(total)) GB").font(F.ui(12)).monospacedDigit().foregroundStyle(T.muted)
            }
            GeometryReader { geo in
                let w = geo.size.width
                HStack(spacing: 2) {
                    Rectangle().fill(T.diskOther).frame(width: max(0, w * (used - nm) / total))
                    Rectangle().fill(T.diskNM).frame(width: max(0, w * (nm - reclaim) / total))
                    Rectangle().fill(T.diskReclaim).frame(width: max(0, w * reclaim / total))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 8)
            .background(T.well)
            .clipShape(Capsule())
            .help("\(Int(used / total * 100))% used")
            VStack(spacing: 6) {
                legend(T.diskNM, "Deps & builds", gbText(nm), T.fg)
                legend(T.diskReclaim, "Reclaimable", gbText(reclaim), T.amber)
            }
            Button { showCleanup = true } label: {
                Label(cands == 0 ? "Nothing to clean" : "Clean up \(plural(cands, "worktree"))", systemImage: "sparkles")
                    .labelStyle(GapLabel())
            }
            .buttonStyle(TButtonStyle(kind: .invert))
            .disabled(cands == 0 || store.busy != nil)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(dyn(oklch(1, 0, 0, 0.7), oklch(0.16, 0.008, 250, 0.6))))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(T.hairSoft))
    }

    func sysRow(_ k: String, _ v: String, _ values: [Double], _ c: Color, ceiling: Double) -> some View {
        HStack(spacing: 8) {
            Text(k).foregroundStyle(T.muted).frame(width: 54, alignment: .leading)
            Text(v).monospacedDigit().foregroundStyle(T.fg).lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            Sparkline(values: values, color: c, ceiling: ceiling, stretch: true).frame(height: 18).frame(minWidth: 30)
        }
        .font(F.ui(12))
    }

    func legend(_ c: Color, _ k: String, _ v: String, _ emphasized: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 8)
            Text(k).foregroundStyle(T.muted)
            Spacer()
            Text(v).monospacedDigit().fontWeight(k == "Reclaimable" ? .semibold : .regular).foregroundStyle(emphasized)
        }
        .font(F.ui(12))
    }
}
