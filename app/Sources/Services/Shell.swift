import AppKit
import SwiftUI

enum Shell {
    static func run(_ exe: String, _ args: [String]) async -> (Int32, String, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                var errData = Data()
                let errDone = DispatchSemaphore(value: 0)
                do { try p.run() } catch {
                    cont.resume(returning: (-1, "", "\(error)"))
                    return
                }
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    errDone.signal()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                errDone.wait()
                cont.resume(returning: (p.terminationStatus,
                                        String(decoding: outData, as: UTF8.self),
                                        String(decoding: errData, as: UTF8.self)))
            }
        }
    }

    static func open(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        try? p.run()
    }
}

enum Alerts {
    static func confirm(_ title: String, _ body: String, button: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .warning
        a.addButton(withTitle: button).hasDestructiveAction = true
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    static func prompt(_ title: String, _ body: String, placeholder: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        a.accessoryView = field
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    static func info(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.runModal()
    }
}
