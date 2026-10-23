// Duo Mac launcher.
//
// macOS remembers Screen Recording / Accessibility permission per signed app. Without a developer
// certificate every rebuild would look like a new app and lose those permissions. So this tiny
// launcher (built once, never changed) is the app you grant permissions to, and it starts the real
// helper (build/Duo Mac) as its child — children inherit the launcher's permissions, just like
// commands run from Terminal inherit Terminal's. The helper can then be rebuilt freely.
import AppKit

final class Launcher: NSObject, NSApplicationDelegate {
    private var child: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let helper = findHelper() else {
            fail("The Duo Mac helper hasn't been built yet.",
                 "Open Terminal in the macbook-nano folder and run ./build.sh, then open Duo Mac again.")
            return
        }
        let p = Process()
        p.executableURL = helper
        p.arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
        var env = ProcessInfo.processInfo.environment
        env["NANO_LAUNCHER_APP"] = Bundle.main.bundlePath
        p.environment = env
        p.terminationHandler = { _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        do {
            try p.run()
            child = p
        } catch {
            fail("Couldn't start the Duo Mac helper.", error.localizedDescription)
            return
        }
        // Let the helper bring its window to the front (macOS 14 cooperative activation).
        for delay in [0.3, 0.9] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let pid = self?.child?.processIdentifier,
                      let app = NSRunningApplication(processIdentifier: pid) else { return }
                NSApp.yieldActivation(to: app)
                app.activate()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again while it runs: ask the helper to show its window.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.riccardoconti.duomac.show"), object: nil, userInfo: nil, deliverImmediately: true)
        if let pid = child?.processIdentifier, let app = NSRunningApplication(processIdentifier: pid) {
            NSApp.yieldActivation(to: app)
            app.activate()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let c = child, c.isRunning else { return }
        c.terminate()
        let deadline = Date().addingTimeInterval(1.5)
        while c.isRunning && Date() < deadline { usleep(20_000) }
    }

    private func findHelper() -> URL? {
        // Installed copy first (./build.sh puts it there): it lives outside ~/Documents, so macOS
        // doesn't stop the helper to ask for Documents access.
        var candidates = [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Duo Mac/Duo Mac")]
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("build/Duo Mac"))
        if let p = Bundle.main.object(forInfoDictionaryKey: "NanoHelperPath") as? String {
            candidates.append(URL(fileURLWithPath: p))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func fail(_ title: String, _ detail: String) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        a.runModal()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let launcher = Launcher()
app.delegate = launcher
app.setActivationPolicy(.accessory)
app.run()
