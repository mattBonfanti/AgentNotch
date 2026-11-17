import Foundation

/// Start-at-login via a plain LaunchAgent. Works for locally built, ad-hoc
/// signed apps, where SMAppService registration is unreliable.
enum LoginItem {
    // Derived from the bundle so a side-by-side test build never rewrites the
    // installed app's LaunchAgent. The regular bundle is still local.agentnotch.
    private static let label = Bundle.main.bundleIdentifier ?? "local.agentnotch"
    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        let fm = FileManager.default
        guard on else {
            try? fm.removeItem(at: plistURL)
            return false
        }
        // Bundle.main.bundlePath is the .app when bundled, the binary when not.
        let bundle = Bundle.main.bundlePath
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": bundle.hasSuffix(".app")
                ? ["/usr/bin/open", "-a", bundle]
                : [bundle],
            "RunAtLoad": true,
            "KeepAlive": false
        ]
        try? fm.createDirectory(at: plistURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0) else { return false }
        try? data.write(to: plistURL)
        return true
    }
}
