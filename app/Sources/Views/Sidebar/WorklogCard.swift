import AppKit
import Charts
import SwiftUI
import UserNotifications

struct WorklogSlice: Identifiable {
    let id: String
    let seconds: Int
    let color: Color
}

struct WorklogCard: View {
    @EnvironmentObject var store: Store
    @State private var showEntries = false
    static let hues: [Double] = [250, 150, 75, 300, 190, 25, 110, 330]

    var body: some View {
        let w = store.worklog
        let day = w?.day
        let total = day?.total_seconds ?? 0
        let target = w?.target ?? 8 * 3600
        let band = w?.band ?? [7 * 3600, 9 * 3600]
        let byKey = Dictionary(grouping: day?.entries ?? [], by: \.key).map { ($0.key, $0.value.reduce(0) { $0 + $1.seconds }) }
            .sorted { $0.1 > $1.1 }
        var slices = byKey.enumerated().map { i, kv in
            WorklogSlice(id: kv.0, seconds: kv.1, color: Color(nsColor: oklch(0.68, 0.14, Self.hues[i % Self.hues.count])))
        }
        if total < target { slices.append(WorklogSlice(id: "remaining", seconds: target - total, color: T.well)) }
        let state = day?.state ?? "UNDER"
        let tone: Color = state == "BALANCED" ? T.green : state == "OVER" ? T.danger : T.amber
        let delta = total < band[0] ? "needs +\(durationText(band[0] - total)) to 7h"
            : total > band[1] ? "over by \(durationText(total - band[1]))" : "in the 7–9h band"

        return Button { showEntries = true } label: {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Chart(slices) { sl in
                        SectorMark(angle: .value("time", sl.seconds), innerRadius: .ratio(0.64), angularInset: 1.2)
                            .foregroundStyle(sl.color)
                            .cornerRadius(2)
                    }
                    .chartLegend(.hidden)
                    VStack(spacing: 0) {
                        Text(durationText(total)).font(F.ui(12, .bold)).monospacedDigit().foregroundStyle(tone)
                            .lineLimit(1).minimumScaleFactor(0.6).frame(width: 46)
                        Text("of \(durationText(target))").font(F.ui(9.5)).foregroundStyle(T.subtle)
                    }
                }
                .frame(width: 70, height: 70)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("Worklog").font(F.ui(12, .semibold)).foregroundStyle(T.fg).fixedSize()
                        Chip(text: state.lowercased(), tone: Tone(fg: tone, bg: tone.opacity(0.16)), radius: 6)
                    }
                    Text(delta).font(F.ui(11.5)).foregroundStyle(tone)
                    ForEach(Array(slices.filter { $0.id != "remaining" }.prefix(2))) { sl in
                        HStack(spacing: 6) {
                            Circle().fill(sl.color).frame(width: 7, height: 7)
                            Text(sl.id).font(F.ui(11.5)).foregroundStyle(T.muted).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            Text(durationText(sl.seconds)).font(F.ui(11.5)).monospacedDigit().foregroundStyle(T.muted).fixedSize()
                        }
                    }
                    if byKey.count > 2 { Text("+ \(byKey.count - 2) more").font(F.ui(11)).foregroundStyle(T.subtle) }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(dyn(oklch(1, 0, 0, 0.7), oklch(0.16, 0.008, 250, 0.6))))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(T.hairSoft))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Today's Jira worklog against the 7–9h band — click for the entries")
        .popover(isPresented: $showEntries, arrowEdge: .trailing) { WorklogPopover(slices: slices) }
        .onChange(of: showEntries) { if showEntries { store.refreshWorklog() } }
    }
}

struct WorklogPopover: View {
    @EnvironmentObject var store: Store
    let slices: [WorklogSlice]

    var body: some View {
        let day = store.worklog?.day
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Worklog · \(day?.date ?? "today")").font(F.ui(13, .semibold))
                Spacer()
                Text(day.map { "\($0.total) · \($0.state.lowercased())" } ?? "").font(F.ui(12)).foregroundStyle(T.muted)
            }
            .padding(14)
            Rectangle().fill(T.hairSoft).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach((day?.entries ?? []).sorted { $0.started < $1.started }, id: \.self) { e in
                        HStack(alignment: .top, spacing: 10) {
                            Text(String(e.started.dropFirst(11).prefix(5))).font(F.mono(11.5)).foregroundStyle(T.subtle)
                            Circle().fill(slices.first { $0.id == e.key }?.color ?? T.muted).frame(width: 8, height: 8).padding(.top, 4)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(e.key).font(F.ui(12.5, .semibold))
                                    Text(e.timeSpent).font(F.ui(12)).monospacedDigit().foregroundStyle(T.muted)
                                }
                                if let c = e.comment, !c.isEmpty {
                                    Text(c).font(F.ui(11.5)).foregroundStyle(T.muted).lineLimit(2)
                                }
                            }
                        }
                    }
                    if (day?.entries ?? []).isEmpty {
                        Text(store.worklog?.error ?? "Nothing logged yet today.").font(F.ui(12)).foregroundStyle(T.muted)
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 380)
        .foregroundStyle(T.fg)
        .background(T.sheet)
    }
}
