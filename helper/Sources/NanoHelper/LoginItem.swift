import Foundation

/// "Open at login": a LaunchAgent that opens Duo Mac.app when you log in. (The helper has no app
/// bundle of its own to register as a login item, and Duo Mac.app can't change: it holds the
/// permissions.) Five seconds after login it opens the app, unless it's running already (macOS may
/// have reopened it): opening it a second time would bring up its window.
enum LoginItem {
    static let label = "com.riccardoconti.duomac.login"
    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// The launcher that started us, or where it's normally installed.
    static var appPath: String {
        ProcessInfo.processInfo.environment["NANO_LAUNCHER_APP"] ?? "/Applications/Duo Mac.app"
    }

    /// Writes or removes the LaunchAgent to match the setting; leaves it alone when it already does.
    /// It takes effect at the next login. main thread
    static func apply(_ on: Bool) {
        let fm = FileManager.default
        guard on else {
            if fm.fileExists(atPath: file.path) {
                try? fm.removeItem(at: file)
                Log.info("Open at login: off")
            }
            return
        }
        let agent: NSDictionary = [
            "Label": label,
            // The path is the script's $0, never part of the command itself.
            "ProgramArguments": ["/bin/sh", "-c", #"sleep 5; pgrep -qx -U "$(id -u)" DuoMac || /usr/bin/open -g -a "$0""#, appPath],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            // Shown as Duo Mac's in System Settings › General › Login Items.
            "AssociatedBundleIdentifiers": ["com.riccardoconti.duomac"],
        ]
        let current = (try? Data(contentsOf: file)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? NSDictionary
        if current == agent { return }
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
            try data.write(to: file, options: .atomic)
            Log.info("Open at login: on (\(appPath))")
        } catch {
            Log.warn("Open at login: couldn't write \(file.path) (\(error.localizedDescription))")
        }
    }
}
