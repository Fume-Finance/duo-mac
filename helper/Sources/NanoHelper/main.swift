import AppKit

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
Log.verbose = options.verbose

if CommandLine.arguments.contains("--selftest-auth") {
    exit(AuthSelfTest.run() ? 0 : 1)
}

let app = NSApplication.shared
let core = NanoCore(options: options)

// Clean shutdown on Ctrl-C / kill: release any held keys or mouse buttons first.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        core.shutdown()
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}

// Creates the Duo display for a few seconds and reports what macOS did with it.
if CommandLine.arguments.contains("--nano-selftest") {
    func report(_ label: String) {
        print("— \(label)")
        for id in DisplayInfo.activeDisplays() {
            let m = CGDisplayCopyDisplayMode(id)
            print(String(format: "  display %u  bounds %@  mode %dx%d pt / %dx%d px  main=%d builtin=%d mirrors=%u",
                         id, NSStringFromRect(CGDisplayBounds(id)), m?.width ?? 0, m?.height ?? 0,
                         m?.pixelWidth ?? 0, m?.pixelHeight ?? 0, CGDisplayIsMain(id), CGDisplayIsBuiltin(id),
                         CGDisplayMirrorsDisplay(id)))
        }
    }
    report("before")
    let nd = NanoDisplay()
    guard let id = nd.ensure(width: 1280, height: 910) else { print("FAILED to create"); exit(1) }
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    report("created \(id)")
    nd.mirrorAllDisplays()
    RunLoop.current.run(until: Date().addingTimeInterval(2.5))
    report("mirroring")
    nd.destroy()
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    report("after")
    exit(0)
}

if let path = options.snapshotUI {
    UISnapshot.render(core: core, to: path)
    exit(0)
}

let delegate = AppDelegate(core: core, headless: options.headless)
app.delegate = delegate
app.setActivationPolicy(options.headless ? .prohibited : .regular)
app.run()
