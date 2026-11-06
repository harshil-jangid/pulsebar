import AppKit
import PulseBarCore
import SwiftUI

/// A regular app window with the same content as the menu-bar popover.
///
/// Why: macOS can hide (or refuse to show) menu-bar icons, e.g. on crowded
/// notched displays or when a menu-bar manager hides them. PulseBar must stay
/// reachable, so opening the app (Spotlight, Finder, Dock) always shows this
/// window, and it opens by itself at launch if the menu-bar icon was hidden.
/// While it's open PulseBar gets a Dock icon and ⌘-Tab entry; closing it
/// returns PulseBar to a quiet menu-bar app.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    private var window: NSWindow?

    func show(env: AppEnvironment) {
        if window == nil {
            let host = NSHostingController(rootView: PopoverView(env: env, inWindow: true))
            let w = NSWindow(contentViewController: host)
            w.title = "PulseBar"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setFrameAutosaveName("PulseBarMainWindow")
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)   // Dock icon while the window is open
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // back to menu-bar only
    }
}
