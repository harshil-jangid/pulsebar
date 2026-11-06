import PulseBarCore
import SwiftUI

/// Menu-bar app (`LSUIElement`), plus a regular window whenever the user opens
/// the app or the menu-bar icon is hidden (see `MainWindowController`).
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
        AppDelegate.environment = env
        #if DEBUG
        Snapshotter.runIfRequested(env: env)
        #endif
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

        // First-run onboarding: presented at launch only until completed.
        Window("Welcome to PulseBar", id: OnboardingView.windowID) {
            OnboardingView(env: env)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(env.settings.value.onboardingCompleted ? .suppressed : .presented)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let showIconKey = "showMenuBarIcon"
    @MainActor static var environment: AppEnvironment?

    /// If macOS hid the menu-bar icon (SwiftUI flips `isInserted` to false),
    /// open the window so PulseBar is never unreachable.
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                guard !CommandLine.arguments.contains("-snapshot"),
                      !UserDefaults.standard.bool(forKey: Self.showIconKey),
                      let env = Self.environment else { return }
                MainWindowController.shared.show(env: env)
            }
        }
    }

    /// Called when the user opens PulseBar while it's already running
    /// (Spotlight, Finder, Dock): always show the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        UserDefaults.standard.set(true, forKey: Self.showIconKey)
        MainActor.assumeIsolated {
            if let env = Self.environment { MainWindowController.shared.show(env: env) }
        }
        return false
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
