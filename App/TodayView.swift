import PulseBarCore
import SwiftUI

/// Popover "Today": morning readiness vs. personal baseline (F4.2) and last night.
struct TodayView: View {
    let env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !env.google.isConnected && env.dailyRows.isEmpty {
                ContentUnavailableView {
                    Label("Connect Google Health", systemImage: "heart.text.square")
                } description: {
                    Text("Readiness uses your sleep HRV, resting heart rate and sleep from Google Health. Live heart rate works without it.")
                }
            } else if let r = env.readiness {
                card(r)
                lastNight
            }
            Text("Readiness is a simple personal heuristic, not medical advice.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func card(_ r: Readiness) -> some View {
        switch r.state {
        case .calibrating(let n):
            VStack(alignment: .leading, spacing: 6) {
                Label("Calibrating (\(n)/\(Baseline.minimumDays) days)", systemImage: "hourglass")
                    .font(.headline)
                ProgressView(value: Double(n), total: Double(Baseline.minimumDays))
                Text("PulseBar needs 14 days of sleep HRV and resting heart rate to learn your baseline.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .noData:
            Label("Today's sleep data hasn't synced yet.", systemImage: "moon.zzz")
        case .ready:
            if let band = r.band, let score = r.score {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(band.rawValue, systemImage: band.symbol)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(band.color)
                        Spacer()
                        Text("\(score)").font(.title2.monospacedDigit()).foregroundStyle(.secondary)
                            .accessibilityLabel("Readiness score \(score) of 100")
                    }
                    ForEach(r.reasons, id: \.self) { reason in
                        Label(reason.prefix(1).uppercased() + reason.dropFirst(), systemImage: "smallcircle.filled.circle")
                            .font(.callout)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private var lastNight: some View {
        if let today = env.dailyRows.last(where: { $0.date == LocalDay.string(Date()) }) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                if let m = today.sleepMinutes {
                    GridRow { Text("Sleep").foregroundStyle(.secondary); Text("\(m / 60) h \(m % 60) min") }
                }
                if let v = today.hrvMs {
                    GridRow { Text("Sleep HRV").foregroundStyle(.secondary); Text("\(Int(v.rounded())) ms") }
                }
                if let v = today.restingHR {
                    GridRow { Text("Resting HR").foregroundStyle(.secondary); Text("\(Int(v)) bpm") }
                }
            }
            .font(.callout)
        }
    }
}

extension ReadinessBand {
    var color: Color {
        switch self {
        case .goHard: .green
        case .normal: .blue
        case .takeItEasy: .orange
        }
    }
}
