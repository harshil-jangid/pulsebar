import PulseBarCore
import SwiftUI

/// Menu-bar-only app (no Dock icon: `LSUIElement` in project.yml).
/// Launch with `-demo` for simulated heart rate and a throwaway in-memory database.
@main
struct PulseBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var env: AppEnvironment
    /// If macOS (or the user, by ⌘-dragging) removes the menu-bar icon, SwiftUI
    /// sets this to false instead of quitting the app. Opening PulseBar again
    /// (Spotlight, Finder) sets it back to true. See `AppDelegate`.
    @AppStorage(AppDelegate.showIconKey) private var showIcon = true

    init() {
        let env = AppEnvironment(demo: CommandLine.arguments.contains("-demo"))
        env.start()
        _env = State(initialValue: env)
        // A fresh launch always means "I want to see PulseBar".
        UserDefaults.standard.set(true, forKey: AppDelegate.showIconKey)
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $showIcon) {
            PopoverView(env: env)
        } label: {
            MenuBarLabel(bpm: env.live.displayBPM)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(env: env)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let showIconKey = "showMenuBarIcon"

    /// Called when the user opens PulseBar while it's already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        UserDefaults.standard.set(true, forKey: Self.showIconKey)
        return true
    }
}

/// Heart + number. Text is always present, so status is never color-only.
struct MenuBarLabel: View {
    let bpm: Int?

    var body: some View {
        Text("\(Image(systemName: bpm == nil ? "heart" : "heart.fill")) \(bpm.map(String.init) ?? "—")")
            .monospacedDigit()
            .accessibilityLabel(bpm.map { "Heart rate \($0) beats per minute" } ?? "PulseBar, no heart rate")
    }
}
