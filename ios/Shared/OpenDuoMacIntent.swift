import AppIntents

// "Open Duo Mac": the action behind the Control Center / Lock Screen control (DuoMacWidget) and the
// Shortcuts app. Compiled into both the app and the widget extension (ios/Shared/ is in both targets),
// which the system needs so that running it from a control can open the app.

struct OpenDuoMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Duo Mac"
    static let description = IntentDescription("Opens Duo Mac.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}
