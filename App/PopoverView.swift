import PulseBarCore
import SwiftUI

/// The window that drops down from the menu-bar icon.
struct PopoverView: View {
    let env: AppEnvironment
    @Environment(\.openSettings) private var openSettings

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
                    Button("Reconnect") { NSApp.activate(); openSettings() }
                }
            }
            NowView(env: env)
            Divider()
            HStack {
                Text("Not medical advice.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Settings…") {
                    // Menu-bar apps aren't frontmost; bring the Settings window forward.
                    NSApp.activate()
                    openSettings()
                }
                .keyboardShortcut(",")
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding()
        .frame(width: 340)
    }
}
