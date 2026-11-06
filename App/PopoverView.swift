import PulseBarCore
import SwiftUI

enum PopoverTab: String, CaseIterable, Identifiable {
    case now = "Now", today = "Today", progress = "Progress", checkin = "Check-in"
    var id: String { rawValue }
}

/// The window that drops down from the menu-bar icon.
struct PopoverView: View {
    let env: AppEnvironment
    @Environment(\.openSettings) private var openSettings
    @AppStorage("popover.tab") private var tab: PopoverTab = .now

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = env.storageError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption)
            }
            if env.isDemo {
                Label("Demo mode: simulated data, nothing is saved.", systemImage: "theatermasks")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if env.google.status == .reauthRequired {
                HStack {
                    Label("Google sign-in expired.", systemImage: "exclamationmark.arrow.circlepath").font(.callout)
                    Spacer()
                    Button("Reconnect") { showSettings() }
                }
            }
            Picker("Section", selection: $tab) {
                ForEach(PopoverTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .now: NowView(env: env)
            case .today: TodayView(env: env)
            case .progress: GoalProgressView(env: env)
            case .checkin: CheckinView(env: env)
            }

            Divider()
            HStack {
                Text("Not medical advice.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Settings…") { showSettings() }
                    .keyboardShortcut(",")
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding()
        .frame(width: 380)
        .onAppear { env.refreshMetrics() }   // pick up a new day when the popover opens
    }

    private func showSettings() {
        // Menu-bar apps aren't frontmost; bring the Settings window forward.
        NSApp.activate()
        openSettings()
    }
}
