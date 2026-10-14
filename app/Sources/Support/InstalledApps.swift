import AppKit
import SwiftUI

/// Editors found on this Mac (id, label, bundle id), in preference order.
let editors: [(id: String, label: String, app: String)] = {
    let known: [(String, String, [String])] = [
        ("code", "VS Code", ["com.microsoft.VSCode"]),
        ("cursor", "Cursor", ["com.todesktop.230313mzl4w4u92"]),
        ("webstorm", "WebStorm", ["com.jetbrains.WebStorm"]),
        ("goland", "GoLand", ["com.jetbrains.goland"]),
        ("pycharm", "PyCharm", ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce"]),
        ("idea", "IntelliJ IDEA", ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]),
        ("rider", "Rider", ["com.jetbrains.rider"]),
        ("zed", "Zed", ["dev.zed.Zed"]),
        ("sublime", "Sublime Text", ["com.sublimetext.4", "com.sublimetext.3"]),
        ("xcode", "Xcode", ["com.apple.dt.Xcode"]),
    ]
    let found = known.compactMap { id, label, ids -> (id: String, label: String, app: String)? in
        ids.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }.map { (id, label, $0) }
    }
    return found.isEmpty ? [("finder", "Finder", "com.apple.finder")] : found
}()

let hasWarp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.warp.Warp-Stable") != nil
