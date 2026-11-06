import Charts
import PulseBarCore
import SwiftUI

/// Popover "Progress": goal countdown and trend charts vs. the starting baseline (F5).
struct GoalProgressView: View {
    let env: AppEnvironment
    @AppStorage("progress.metric") private var metric: Metric = .hrv
    @AppStorage("progress.period") private var period: TrendPeriod = .day

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            countdown
            Picker("Metric", selection: $metric) {
                ForEach(Metric.allCases) { Text($0.shortTitle).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Picker("Period", selection: $period) {
                Text("Daily").tag(TrendPeriod.day)
                Text("Weekly").tag(TrendPeriod.week)
                Text("Monthly").tag(TrendPeriod.month)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TrendChart(metric: metric, period: period, rows: env.dailyRows,
                       startValue: env.goal?.startSnapshot?.values[metric])
            changeSummary
        }
    }

    @ViewBuilder private var countdown: some View {
        if let goal = env.goal, let days = goal.daysRemaining(from: LocalDay.string(Date())) {
            HStack {
                Label(goal.label, systemImage: "calendar")
                    .font(.headline)
                Spacer()
                Text(days >= 0 ? "\(days) days to go" : "\(-days) days ago")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
        } else {
            Text("Set a goal date in Settings → Goal.").font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Plain-language change vs. start, no invented targets (F5.3).
    @ViewBuilder private var changeSummary: some View {
        let recent = env.dailyRows.suffix(7).compactMap { $0.value(metric) }
        if let start = env.goal?.startSnapshot?.values[metric], let now = RobustStats.median(recent) {
            let delta = now - start
            let better = metric.higherIsBetter ? delta > 0 : delta < 0
            Text("Last 7 days vs. your start: \(Self.format(delta, metric)) \(metric.unit)")
                .font(.callout)
                .foregroundStyle(abs(delta) < 0.5 ? Color.secondary : (better ? Color.green : Color.secondary))
        } else if env.goal != nil {
            Text("Your starting baseline is set after 14 days of data.").font(.caption).foregroundStyle(.secondary)
        }
    }

    static func format(_ v: Double, _ m: Metric) -> String {
        let rounded = m == .hrv ? (v * 10).rounded() / 10 : v.rounded()
        let s = m == .hrv ? String(format: "%.1f", abs(rounded)) : String(Int(abs(rounded)))
        return (rounded > 0 ? "+" : rounded < 0 ? "−" : "±") + s
    }
}

struct TrendChart: View {
    let metric: Metric
    let period: TrendPeriod
    let rows: [DailyMetric]
    let startValue: Double?

    var body: some View {
        let points = Trends.series(metric, rows: rows, period: period)
        if points.isEmpty {
            Text("No \(metric.title.lowercased()) data yet.").font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 140)
        } else {
            Chart {
                ForEach(points) { p in
                    if period == .day {
                        PointMark(x: .value("Date", p.date, unit: .day), y: .value(metric.unit, p.value))
                            .symbolSize(12)
                            .foregroundStyle(.secondary)
                        if let avg = p.rolling7 {
                            LineMark(x: .value("Date", p.date, unit: .day), y: .value("7-day average", avg))
                                .interpolationMethod(.monotone)
                        }
                    } else {
                        BarMark(x: .value("Date", p.date, unit: period == .week ? .weekOfYear : .month),
                                y: .value(metric.unit, p.value))
                    }
                }
                if let startValue {
                    RuleMark(y: .value("Start", startValue))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.orange)
                        .annotation(position: .top, alignment: .leading) {
                            Text("start").font(.caption2).foregroundStyle(.orange)
                        }
                }
            }
            .chartYScale(domain: .automatic(includesZero: metric == .steps))
            .frame(height: 160)
            .accessibilityLabel("\(metric.title) trend, \(period.rawValue)ly")
            .accessibilityValue({
                let last = points.last.map { "latest \(Int(($0.rolling7 ?? $0.value).rounded())) \(metric.unit)" } ?? ""
                let start = startValue.map { ", starting baseline \(Int($0.rounded())) \(metric.unit)" } ?? ""
                return last + start
            }())
        }
    }
}

extension Metric {
    var shortTitle: String {
        switch self {
        case .restingHR: "RHR"
        case .hrv: "HRV"
        case .sleep: "Sleep"
        case .steps: "Steps"
        }
    }
}
