import Charts
import PulseBarCore
import SwiftUI

/// The popover's "Now" view: live BPM, zone, 10-minute chart, device picker.
struct NowView: View {
    let live: LiveHeartRateModel

    @AppStorage("zones.age") private var age = 0
    @AppStorage("zones.maxHROverride") private var maxHROverride = 0

    private var zones: HeartRateZones? {
        maxHROverride > 0 ? HeartRateZones(maxHR: maxHROverride) : HeartRateZones(age: age)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            StatusLine(live: live)
            if !live.samples.isEmpty {
                HeartRateChart(samples: live.samples, window: live.window, zone2: zones?.range(of: .zone2))
            }
            ZoneSettings(age: $age, maxHROverride: $maxHROverride, zones: zones)
            DeviceSection(live: live)
            Divider()
            HStack {
                Text("Not medical advice.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit PulseBar") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding()
        .frame(width: 320)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(live.displayBPM.map(String.init) ?? "—")
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.default, value: live.displayBPM)
            Text("bpm").foregroundStyle(.secondary)
            Spacer()
            if let bpm = live.displayBPM, let zones {
                ZoneBadge(zone: zones.zone(for: bpm))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Pieces

struct ZoneBadge: View {
    let zone: HeartRateZone

    var body: some View {
        Label(zone.title, systemImage: "circle.fill")
            .font(.callout)
            .labelStyle(ZoneLabelStyle(color: zone.color))
    }
}

private struct ZoneLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(color).imageScale(.small)
            configuration.title
        }
    }
}

extension HeartRateZone {
    var color: Color {
        switch self {
        case .belowZones: .gray
        case .zone1: .blue
        case .zone2: .green
        case .zone3: .yellow
        case .zone4: .orange
        case .zone5: .red
        }
    }
}

struct StatusLine: View {
    let live: LiveHeartRateModel

    var body: some View {
        switch live.availability {
        case .unauthorized:
            VStack(alignment: .leading, spacing: 4) {
                Label("Bluetooth access is off for PulseBar.", systemImage: "exclamationmark.triangle")
                Text("Turn it on in System Settings → Privacy & Security → Bluetooth.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .poweredOff:
            Label("Bluetooth is off.", systemImage: "antenna.radiowaves.left.and.right.slash")
        case .unsupported:
            Label("This Mac doesn't support Bluetooth Low Energy.", systemImage: "xmark.circle")
        case .unknown, .resetting:
            Label("Starting Bluetooth…", systemImage: "antenna.radiowaves.left.and.right")
        case .poweredOn:
            connectionText
        }
    }

    @ViewBuilder private var connectionText: some View {
        switch live.connection {
        case .idle:
            Label(live.rememberedDeviceID == nil ? "No device selected." : "Not connected.",
                  systemImage: "heart.slash")
        case .connecting(let name):
            Label("Connecting to \(name)…", systemImage: "antenna.radiowaves.left.and.right")
        case .connected(let name):
            if let latest = live.latest, !latest.hasValidContact {
                Label("\(name): no skin contact", systemImage: "hand.raised")
            } else {
                Label("Connected to \(name)", systemImage: "checkmark.circle")
            }
        case .reconnecting(let name):
            Label("Waiting for \(name) to come back in range…", systemImage: "arrow.clockwise")
        }
    }
}

struct HeartRateChart: View {
    let samples: [HeartRateSample]
    let window: TimeInterval
    let zone2: ClosedRange<Int>?

    var body: some View {
        let end = samples.last?.date ?? .now
        let start = end.addingTimeInterval(-window)
        Chart {
            if let zone2 {
                RectangleMark(xStart: .value("Start", start), xEnd: .value("End", end),
                              yStart: .value("Zone 2 low", zone2.lowerBound),
                              yEnd: .value("Zone 2 high", zone2.upperBound))
                    .foregroundStyle(.green.opacity(0.15))
                    .accessibilityLabel("Zone 2 band")
            }
            ForEach(samples) { sample in
                LineMark(x: .value("Time", sample.date), y: .value("BPM", sample.bpm))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.red)
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis(.hidden)
        .frame(height: 90)
        .accessibilityLabel("Heart rate, last 10 minutes")
    }
}

struct ZoneSettings: View {
    @Binding var age: Int
    @Binding var maxHROverride: Int
    let zones: HeartRateZones?

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Stepper("Age: \(age == 0 ? "not set" : String(age))",
                        value: $age, in: 0...100)
                Toggle("Use my own max heart rate", isOn: Binding(
                    get: { maxHROverride > 0 },
                    set: { maxHROverride = $0 ? (zones?.maxHR ?? 190) : 0 }))
                if maxHROverride > 0 {
                    Stepper("Max HR: \(maxHROverride) bpm", value: $maxHROverride,
                            in: HeartRateZones.plausibleMaxHR)
                }
            }
            .padding(.top, 4)
        } label: {
            if let zones {
                let z2 = zones.range(of: .zone2)
                Text("Zone 2 (easy): \(z2.lowerBound)–\(z2.upperBound) bpm · max \(zones.maxHR)")
            } else {
                Text("Set your age to see heart-rate zones")
            }
        }
        .font(.callout)
    }
}

struct DeviceSection: View {
    let live: LiveHeartRateModel
    @State private var showPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Device").font(.callout.weight(.medium))
                Spacer()
                if live.rememberedDeviceID != nil {
                    Button("Forget") { live.forgetDevice() }
                }
                Button(live.isScanning ? "Stop" : "Find devices") {
                    live.isScanning ? live.stopScan() : live.startScan()
                }
                .disabled(live.availability != .poweredOn)
            }
            if live.isScanning {
                if live.discovered.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Looking for heart-rate devices…").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("On Fitbit Air, turn on “Share heart rate”.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(live.discovered) { device in
                    HStack {
                        Text(device.name)
                        Spacer()
                        Button("Connect") { live.connect(to: device) }
                    }
                }
            }
        }
    }
}
