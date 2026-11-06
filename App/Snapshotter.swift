#if DEBUG
import AppKit
import PulseBarCore
import SwiftUI

/// Debug-only: `PulseBar -demo -snapshot <dir>` renders the real views to PNGs
/// and quits. Used to check UI without clicking through it, and for README images.
@MainActor
enum Snapshotter {
    static func runIfRequested(env: AppEnvironment) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        // Let demo heart rate fill the chart for a few seconds first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for tab in PopoverTab.allCases {
                UserDefaults.standard.set(tab.rawValue, forKey: "popover.tab")
                render(PopoverView(env: env), to: dir.appending(path: "popover-\(tab.rawValue.lowercased()).png"))
            }
            render(OnboardingView(env: env), to: dir.appending(path: "onboarding.png"))
            render(GeneralSettings(settings: env.settings).frame(width: 600, height: 560), to: dir.appending(path: "settings-general.png"))
            render(NudgeSettings(env: env).frame(width: 600, height: 560), to: dir.appending(path: "settings-nudges.png"))
            render(GoalSettings(env: env).frame(width: 600, height: 560), to: dir.appending(path: "settings-goal.png"))
            render(GoogleSettings(env: env).frame(width: 600, height: 900), to: dir.appending(path: "settings-google.png"))
            NSApp.terminate(nil)
        }
    }

    static func render<V: View>(_ view: V, to url: URL) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: .aqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
