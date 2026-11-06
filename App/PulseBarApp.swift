import PulseBarCore
import SwiftUI

/// Menu-bar-only app (no Dock icon: `LSUIElement` in project.yml).
@main
struct PulseBarApp: App {
    @State private var live: LiveHeartRateModel

    init() {
        let demo = CommandLine.arguments.contains("-demo")
        let source: HeartRateSource = demo ? DemoHeartRateSource() : CoreBluetoothHeartRateSource()
        let defaults = demo ? UserDefaults(suiteName: "PulseBarDemo")! : .standard
        if demo {
            defaults.set(DemoHeartRateSource.deviceID.uuidString, forKey: LiveHeartRateModel.rememberedDeviceKey)
        }
        let model = LiveHeartRateModel(source: source, defaults: defaults)
        model.start() // starts Bluetooth so a remembered device reconnects at launch
        _live = State(initialValue: model)
    }

    var body: some Scene {
        MenuBarExtra {
            NowView(live: live)
        } label: {
            MenuBarLabel(bpm: live.displayBPM)
        }
        .menuBarExtraStyle(.window)
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
