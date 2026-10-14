import AppKit
import SwiftUI

func oklch(_ L: Double, _ C: Double, _ h: Double, _ alpha: Double = 1) -> NSColor {
    let a = C * cos(h * .pi / 180), b = C * sin(h * .pi / 180)
    let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
    let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
    let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
    func gamma(_ x: Double) -> CGFloat {
        let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        return CGFloat(min(max(v, 0), 1))
    }
    return NSColor(srgbRed: gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                   green: gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                   blue: gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
                   alpha: CGFloat(alpha))
}

func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    })
}

enum T {
    static let bg = dyn(oklch(0.985, 0.003, 250), oklch(0.16, 0.008, 250))
    static let panel = dyn(oklch(1, 0, 0), oklch(0.18, 0.008, 250))
    static let section = dyn(oklch(0.975, 0.003, 250), oklch(0.21, 0.009, 250))
    static let control = dyn(oklch(1, 0, 0), oklch(0.23, 0.010, 250))
    static let controlHover = dyn(oklch(0.965, 0.004, 250), oklch(0.28, 0.010, 250))
    static let sidebar = dyn(oklch(0.965, 0.004, 250, 0.9), oklch(0.22, 0.010, 250, 0.72))
    static let sheet = dyn(oklch(1, 0, 0), oklch(0.20, 0.009, 250))
    static let well = dyn(oklch(0.94, 0.005, 250), oklch(0.28, 0.010, 250))
    static let hair = dyn(oklch(0.18, 0.01, 250, 0.09), oklch(0.97, 0.003, 250, 0.07))
    static let hairSoft = dyn(oklch(0.18, 0.01, 250, 0.06), oklch(0.97, 0.003, 250, 0.05))
    static let hover = dyn(oklch(0.18, 0.01, 250, 0.04), oklch(0.97, 0.003, 250, 0.04))
    static let navOn = dyn(oklch(0.18, 0.01, 250, 0.07), oklch(0.97, 0.003, 250, 0.10))
    static let navHover = dyn(oklch(0.18, 0.01, 250, 0.04), oklch(0.97, 0.003, 250, 0.06))

    static let fg = dyn(oklch(0.18, 0.01, 250), oklch(0.97, 0.003, 250))
    static let muted = dyn(oklch(0.45, 0.01, 250), oklch(0.74, 0.006, 250))
    static let subtle = dyn(oklch(0.56, 0.008, 250), oklch(0.58, 0.008, 250))
    static let faint = dyn(oklch(0.78, 0.005, 250), oklch(0.42, 0.008, 250))

    static let accent = Color(nsColor: oklch(0.55, 0.18, 250))
    static let accentText = dyn(oklch(0.50, 0.18, 250), oklch(0.72, 0.14, 250))
    static let accentSoft = dyn(oklch(0.55, 0.18, 250, 0.10), oklch(0.65, 0.18, 250, 0.18))
    static let accentBorder = dyn(oklch(0.55, 0.18, 250, 0.40), oklch(0.65, 0.18, 250, 0.45))
    static let onAccent = Color(nsColor: oklch(0.99, 0, 0))

    static let amber = dyn(oklch(0.60, 0.14, 65), oklch(0.80, 0.14, 75))
    static let amberSoft = dyn(oklch(0.80, 0.14, 75, 0.18), oklch(0.80, 0.14, 75, 0.16))
    static let amberRow = dyn(oklch(0.80, 0.14, 75, 0.10), oklch(0.80, 0.14, 75, 0.07))
    static let green = dyn(oklch(0.52, 0.15, 150), oklch(0.80, 0.17, 150))
    static let greenSoft = Color(nsColor: oklch(0.72, 0.17, 150, 0.16))
    static let danger = dyn(oklch(0.52, 0.20, 25), oklch(0.78, 0.14, 25))
    static let dangerSoft = Color(nsColor: oklch(0.65, 0.20, 25, 0.12))
    static let dangerBorder = Color(nsColor: oklch(0.65, 0.20, 25, 0.35))
    static let purple = dyn(oklch(0.50, 0.16, 300), oklch(0.80, 0.12, 300))
    static let purpleSoft = Color(nsColor: oklch(0.68, 0.16, 300, 0.18))
    static let blue = dyn(oklch(0.50, 0.16, 250), oklch(0.80, 0.10, 250))
    static let blueSoft = Color(nsColor: oklch(0.65, 0.18, 250, 0.16))
    static let neutralSoft = dyn(oklch(0.18, 0.01, 250, 0.06), oklch(0.97, 0.003, 250, 0.08))

    static let diskOther = dyn(oklch(0.72, 0.008, 250), oklch(0.58, 0.008, 250))
    static let diskNM = Color(nsColor: oklch(0.65, 0.16, 250))
    static let diskReclaim = Color(nsColor: oklch(0.80, 0.14, 75))
}

enum F {
    static let hasInter = NSFont(name: "Inter", size: 12) != nil
    static let hasJB = NSFont(name: "JetBrains Mono", size: 12) != nil

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        hasInter ? .custom("Inter", size: size).weight(weight) : .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        hasJB ? .custom("JetBrains Mono", size: size).weight(weight) : .system(size: size, weight: weight, design: .monospaced)
    }
}

struct Tone { let fg: Color; let bg: Color }
