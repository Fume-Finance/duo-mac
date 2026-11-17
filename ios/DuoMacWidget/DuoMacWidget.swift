import AppIntents
import SwiftUI
import WidgetKit

// Duo Mac buttons outside the app: a Lock Screen widget (tapping a Lock Screen widget opens its app)
// and a Control Center / Lock Screen control (iOS 18) that runs OpenDuoMacIntent (ios/Shared/).

@main
struct DuoMacWidgets: WidgetBundle {
    var body: some Widget {
        DuoMacLockScreenWidget()
        DuoMacControl()
    }
}

// ── Lock Screen widget ──

struct DuoMacEntry: TimelineEntry {
    let date: Date
}

struct DuoMacProvider: TimelineProvider {
    func placeholder(in context: Context) -> DuoMacEntry { DuoMacEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (DuoMacEntry) -> Void) {
        completion(DuoMacEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DuoMacEntry>) -> Void) {
        completion(Timeline(entries: [DuoMacEntry(date: .now)], policy: .never)) // nothing ever changes
    }
}

struct DuoMacLockScreenView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer")
                    .font(.title2)
                Text("Duo Mac")
                    .font(.headline)
                    .widgetAccentable()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "laptopcomputer")
                    .font(.title3)
            }
        }
    }
}

struct DuoMacLockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DuoMacLockScreen", provider: DuoMacProvider()) { _ in
            DuoMacLockScreenView()
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Duo Mac")
        .description("Opens Duo Mac.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

// ── Control Center control ──

struct DuoMacControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.riccardoconti.duomac.phone.widget.open") {
            ControlWidgetButton(action: OpenDuoMacIntent()) {
                Label("Duo Mac", systemImage: "laptopcomputer")
            }
        }
        .displayName("Open Duo Mac")
        .description("Opens Duo Mac.")
    }
}
