import AppKit
import SwiftUI

enum Snapshot {
    static let args = CommandLine.arguments
    static var path: String? { value(after: "--snapshot") }
    static var select: String? { value(after: "--select") }
    static var group: String? { value(after: "--group") }
    static var cleanup: Bool { args.contains("--cleanup") }
    static var light: Bool { args.contains("--light") }
    private static var scheduled = false

    static func value(after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func schedule() {
        guard let path, !scheduled else { return }
        scheduled = true
        if let h = Double(value(after: "--height") ?? ""),
           let main = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) {
            main.setContentSize(NSSize(width: main.frame.width, height: h))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (Double(value(after: "--delay") ?? "") ?? 1.8)) {
            guard let main = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) else { exit(1) }
            let win = main.attachedSheet ?? main
            guard let view = win.contentView?.superview ?? win.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}
