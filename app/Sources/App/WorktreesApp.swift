import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if Snapshot.light { NSApp.appearance = NSAppearance(named: .aqua) }
        if Snapshot.path == nil { NSApp.activate(ignoringOtherApps: true) }
        for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didEndLiveResizeNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                (note.object as? NSWindow).map(TrafficLights.place)
            }
        }
        DispatchQueue.main.async {
            NSApp.windows.forEach { w in
                w.isMovableByWindowBackground = true
                TrafficLights.place(w)
            }
        }
    }
}

/// The design puts the window buttons inside the floating sidebar panel (8pt inset + 14pt padding),
/// so the titlebar container is made 56pt tall and the buttons are centred in it.
enum TrafficLights {
    static func place(_ w: NSWindow) {
        guard w.frame.width > 600, !w.styleMask.contains(.fullScreen),
              let close = w.standardWindowButton(.closeButton),
              let titlebar = close.superview, let container = titlebar.superview else { return }
        let h: CGFloat = 56
        container.frame = NSRect(x: 0, y: w.frame.height - h, width: w.frame.width, height: h)
        titlebar.frame = container.bounds
        for (i, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let b = w.standardWindowButton(type) else { continue }
            b.setFrameOrigin(NSPoint(x: 22 + CGFloat(i) * 20, y: (h - b.frame.height) / 2))
        }
    }
}

@main
struct WorktreeBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store()

    var body: some Scene {
        Window("Worktrees", id: "main") {
            MainView()
                .environmentObject(store)
                .frame(minWidth: 1120, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)

        MenuBarExtra {
            MenuBarView().environmentObject(store)
        } label: {
            Image(systemName: "arrow.triangle.branch")
        }
        .menuBarExtraStyle(.window)
    }
}
