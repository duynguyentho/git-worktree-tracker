import AppKit
import SwiftUI

enum ButtonKind { case primary, secondary, danger, invert }

struct TButtonStyle: ButtonStyle {
    var kind: ButtonKind = .secondary
    var height: CGFloat = 36
    var square = false

    func makeBody(configuration: Configuration) -> some View {
        TButtonBody(configuration: configuration, kind: kind, height: height, square: square)
    }
}

private struct TButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: ButtonKind
    let height: CGFloat
    let square: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        let (bg, fg, border): (Color, Color, Color) = {
            switch kind {
            case .primary: return (T.accent, T.onAccent, .clear)
            case .danger: return (T.dangerSoft, T.danger, T.dangerBorder)
            case .invert: return (T.fg, T.bg, .clear)
            case .secondary: return (hover ? T.controlHover : T.control, T.fg, T.hair)
            }
        }()
        configuration.label
            .font(F.ui(13, kind == .secondary ? .medium : .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, square ? 0 : 14)
            .frame(width: square ? height : nil, height: height)
            .frame(maxWidth: kind == .invert ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(bg))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(border))
            .overlay {
                if kind == .primary {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center))
                }
            }
            .brightness(configuration.isPressed ? -0.06 : (hover && kind != .secondary ? 0.04 : 0))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

struct Chip: View {
    let text: String
    let tone: Tone
    var radius: CGFloat = 99

    var body: some View {
        Text(text)
            .font(F.ui(11.5, .semibold))
            .lineLimit(1)
            .padding(.horizontal, radius > 10 ? 9 : 7)
            .padding(.vertical, radius > 10 ? 3 : 1.5)
            .foregroundStyle(tone.fg)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tone.bg))
    }
}

struct Glyph: View {
    let state: String
    var size: CGFloat = 30

    var body: some View {
        let st = StateStyle.of(state)
        Image(systemName: st.symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(st.tone.fg)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(st.tone.bg))
    }
}

struct SectionBox<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(title)
            }
            .font(F.ui(12, .semibold))
            .foregroundStyle(T.muted)
            content
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(T.section))
    }
}

struct Tile: View {
    let label: String
    let value: String
    var tint: Color = T.fg
    var big: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(F.ui(11.5, .medium)).foregroundStyle(T.subtle)
            Text(value).font(F.ui(big, big > 18 ? .bold : .semibold)).monospacedDigit().foregroundStyle(tint).lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.section))
    }
}

extension View {
    func panel(_ radius: CGFloat = 16) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(T.panel))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(T.hairSoft))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct SegmentedControl: View {
    @Binding var value: GroupBy

    var body: some View {
        HStack(spacing: 0) {
            ForEach(GroupBy.allCases, id: \.self) { g in
                Button { withAnimation(.snappy(duration: 0.2)) { value = g } } label: {
                    Text(g.rawValue)
                        .font(F.ui(12, value == g ? .semibold : .medium))
                        .foregroundStyle(value == g ? T.fg : T.muted)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background {
                            if value == g {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(dyn(oklch(1, 0, 0), oklch(0.34, 0.011, 250)))
                                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(dyn(oklch(0.95, 0.004, 250), oklch(0.22, 0.010, 250))))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(T.hairSoft))
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 10, weight: .bold))
            configuration.title
        }
    }
}

struct GapLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.font(.system(size: 13, weight: .semibold))
            configuration.title
        }
    }
}
