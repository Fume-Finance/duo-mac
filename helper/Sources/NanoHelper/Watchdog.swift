import Foundation

/// Duo Mac.app starts the helper as its child and quits when the helper ends, so after a crash
/// nothing would bring Duo Mac back. A small shell script, left running beside the helper, waits for
/// it to end and, unless it quit on purpose (`markCleanExit`), opens Duo Mac.app again 3 s later: at
/// most 3 times in 10 minutes, so something that crashes right at launch doesn't loop.
///
/// The script waits on a pipe whose only writing end the helper holds and never closes: the pipe
/// closes when the helper's process ends, however it ends (a crash, Force Quit), with no polling.
enum Watchdog {
    /// Small files next to the settings: a "quit on purpose" mark per process, and when the last
    /// restarts were.
    private static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Duo Mac/watchdog")
    }
    private static var marker: URL { dir.appendingPathComponent("clean-exit-\(getpid())") }
    /// The helper's end of the pipe, once started. Never closed: it closes as the process ends.
    private static var lifeline: Int32 = -1

    /// $1 the helper's process ID, $2 Duo Mac.app's (its parent), $3 Duo Mac.app, $4 `dir`.
    /// (After the pipe closes, it also checks the helper is really gone, in case reading stopped early.)
    private static let script = #"""
        while read -r line; do :; done
        while kill -0 "$1" 2>/dev/null; do sleep 1; done
        marker="$4/clean-exit-$1"
        if [ -e "$marker" ]; then rm -f "$marker"; exit 0; fi
        log="$HOME/Library/Logs/Duo Mac/helper.log"
        now=$(date +%s)
        recent=$(awk -v now="$now" 'now - $1 < 600' "$4/restarts" 2>/dev/null)
        if [ "$(printf '%s' "$recent" | grep -c .)" -ge 3 ]; then
          echo "$(date '+%Y-%m-%d %H:%M:%S.000') ! Duo Mac stopped unexpectedly again: not opening it again (3 times in 10 minutes)" >> "$log"
          exit 0
        fi
        { [ -n "$recent" ] && printf '%s\n' "$recent"; echo "$now"; } > "$4/restarts"
        echo "$(date '+%Y-%m-%d %H:%M:%S.000') ! Duo Mac stopped unexpectedly: opening it again" >> "$log"
        i=0; while kill -0 "$2" 2>/dev/null && [ $i -lt 20 ]; do sleep 0.5; i=$((i+1)); done
        sleep 3
        pgrep -qx -U "$(id -u)" DuoMac || /usr/bin/open -g -a "$3"
        """#

    /// Only when started by Duo Mac.app (`NANO_LAUNCHER_APP`), never for test runs. main thread
    static func start() {
        guard let app = ProcessInfo.processInfo.environment["NANO_LAUNCHER_APP"], lifeline < 0 else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // A mark left behind: by an earlier process with the same number, or by scripts stopped before
        // they could tidy up (logging out). A script reads its mark the moment its helper ends.
        try? fm.removeItem(at: marker)
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files where f.lastPathComponent.hasPrefix("clean-exit-") {
            let changed = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(changed) > 600 { try? fm.removeItem(at: f) }
        }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }
        // Only the script's stdin may hold the pipe: no other program the helper starts gets an end of it.
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        let reading = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "duo-mac-watchdog", "\(getpid())", "\(getppid())", app, dir.path]
        p.standardInput = reading
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            Log.warn("Crash restart unavailable: \(error.localizedDescription)")
            close(fds[1])
            return
        }
        try? reading.close()
        lifeline = fds[1]
    }

    /// Quitting on purpose (Quit, Relaunch, Duo Mac.app or the installer asking it to): Duo Mac stays
    /// closed. Call before every deliberate exit.
    static func markCleanExit() {
        guard lifeline >= 0 else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: nil)
    }
}
