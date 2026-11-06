import PulseBarCore
import SwiftUI

/// Menu-bar-only app (no Dock icon: `LSUIElement` in project.yml).
/// M0 placeholder: heart icon + "—" until live HR arrives in M1.
@main
struct PulseBarApp: App {
    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 8) {
                Text("PulseBar \(PulseBarCore.version)").font(.headline)
                Text("No heart-rate device connected.")
                    .foregroundStyle(.secondary)
                Divider()
                Button("Quit PulseBar") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding()
            .frame(width: 240)
        } label: {
            // Text is always present, never color-only (spec §4 accessibility).
            Label("—", systemImage: "heart")
                .labelStyle(.titleAndIcon)
                .accessibilityLabel("PulseBar, no heart rate")
        }
        .menuBarExtraStyle(.window)
    }
}
