import AppKit
import Charts
import SwiftUI

struct Sparkline: View {
    let values: [Double]
    let color: Color
    var ceiling: Double? = nil
    var stretch = false

    var body: some View {
        GeometryReader { g in
            let top = max(ceiling ?? (values.max() ?? 1), 0.0001)
            let span = CGFloat(max((stretch ? values.count : Store.historyLength) - 1, 1))
            let offset = stretch ? 0 : CGFloat(Store.historyLength - values.count)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: g.size.width * (CGFloat(i) + offset) / span,
                        y: g.size.height * (1 - CGFloat(min(v / top, 1))))
            }
            ZStack {
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: CGPoint(x: f.x, y: g.size.height))
                    pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height))
                }
                .fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let f = pts.first else { return }
                    p.move(to: f)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
    }
}

struct LiveChart: View {
    let title: String
    let samples: [LiveSample]
    let value: (LiveSample) -> Double
    let format: (Double) -> String
    let color: Color

    var body: some View {
        let now = samples.last.map(value) ?? 0
        let peak = samples.map(value).max() ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(F.ui(11.5, .medium)).foregroundStyle(T.subtle)
                Spacer()
                Text("peak \(format(peak))").font(F.ui(11)).monospacedDigit().foregroundStyle(T.subtle)
            }
            Text(format(now)).font(F.ui(20, .bold)).monospacedDigit().foregroundStyle(color)
                .contentTransition(.numericText())
            Chart(samples, id: \.t) { s in
                AreaMark(x: .value("t", s.t), y: .value(title, value(s)))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.30), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", s.t), y: .value(title, value(s)))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.monotone)
            }
            .chartXScale(domain: Date().addingTimeInterval(-Double(Store.historyLength))...Date())
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(T.hairSoft)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(format(d)).font(F.ui(10)).foregroundStyle(T.subtle) } }
                }
            }
            .frame(height: 90)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(dyn(oklch(1, 0, 0), oklch(0.18, 0.008, 250))))
    }
}

struct LiveDot: View {
    var compact = false
    @State private var on = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(T.green).frame(width: 7, height: 7)
                .opacity(on ? 1 : 0.35)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            if !compact { Text("LIVE · 1s").font(F.ui(10.5, .bold)).tracking(0.4).foregroundStyle(T.green) }
        }
        .onAppear { on = true }
    }
}
