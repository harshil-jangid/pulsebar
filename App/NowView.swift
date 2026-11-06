import Charts
import PulseBarCore
import SwiftUI

/// The popover's "Now" view: live BPM, zone, session, 10-minute chart, device picker.
struct NowView: View {
    let env: AppEnvironment
    private var live: LiveHeartRateModel { env.live }
    private var zones: HeartRateZones? { env.settings.value.zones }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            StatusLine(live: live)
            if !live.samples.isEmpty {
                HeartRateChart(samples: live.samples, window: live.window, zone2: zones?.range(of: .zone2))
            }
            zoneSummary
            SessionRow(recorder: env.recorder)
            DeviceSection(live: live)
        }
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

    @ViewBuilder private var zoneSummary: some View {
        if let zones {
            let z2 = zones.range(of: .zone2)
            Text("Zone 2 (easy): \(z2.lowerBound)–\(z2.upperBound) bpm · max \(zones.maxHR)")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Text("Set your age in Settings to see heart-rate zones.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Pieces

struct SessionRow: View {
    let recorder: SessionRecorder

    var body: some View {
        HStack {
            if let s = recorder.current {
                Label {
                    Text("\(s.kind == .workout ? "Workout" : "Desk session") · \(s.start, style: .timer)")
                } icon: {
                    Image(systemName: s.kind == .workout ? "figure.run" : "desktopcomputer")
                }
                .font(.callout)
                .monospacedDigit()
            } else {
                Label("No session", systemImage: "pause.circle").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if recorder.isWorkout {
                Button("End workout") { recorder.endWorkout() }
            } else {
                Button("Start workout") { recorder.startWorkout() }
                    .help("Workouts are saved separately and pause desk nudges.")
            }
        }
    }
}

struct ZoneBadge: View {
    let zone: HeartRateZone

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.fill").foregroundStyle(zone.color).imageScale(.small)
            Text(zone.title)
        }
        .font(.callout)
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

/// Whether live HRV (spec F2.5) will be possible with this device.
/// "Not sent" is only claimed after 10 readings, so one RR-less packet isn't misread.
struct RRStatus: View {
    let sendsRR: Bool
    let readings: Int

    var body: some View {
        Group {
            if sendsRR {
                Label("Beat-to-beat (RR) data: yes", systemImage: "waveform.path.ecg")
            } else if readings < 10 {
                Label("Beat-to-beat (RR) data: checking…", systemImage: "waveform.path.ecg")
            } else {
                Label("Beat-to-beat (RR) data: not sent by this device", systemImage: "waveform.path.ecg")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct DeviceSection: View {
    let live: LiveHeartRateModel

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
            if case .connected = live.connection {
                RRStatus(sendsRR: live.deviceSendsRR, readings: live.readingsThisConnection)
            }
            if live.isScanning {
                if live.discovered.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Looking for heart-rate devices…").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("On Fitbit Air, turn on “Share heart rate” in the Google Health app.")
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
