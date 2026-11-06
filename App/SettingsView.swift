import PulseBarCore
import SwiftUI

/// The Settings window (⌘,). One tab per area; later milestones add more.
struct SettingsView: View {
    let env: AppEnvironment

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings(settings: env.settings) }
            Tab("Nudges", systemImage: "figure.walk") { NudgeSettings(env: env) }
            Tab("Goal", systemImage: "flag.checkered") { GoalSettings(env: env) }
            Tab("Check-in", systemImage: "checklist") { CheckinSettings(env: env) }
            Tab("Google", systemImage: "heart.text.square") { GoogleSettings(env: env) }
        }
        .frame(width: 600, height: 560)
    }
}

/// Binding into one field of the stored settings; every edit saves.
@MainActor
func binding<T>(_ settings: SettingsStore, _ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
    Binding(get: { settings.value[keyPath: keyPath] },
            set: { newValue in settings.update { $0[keyPath: keyPath] = newValue } })
}

/// Edits a minutes-since-midnight value with a time picker.
struct MinuteOfDayPicker: View {
    let title: String
    @Binding var minute: Int

    var body: some View {
        DatePicker(title, selection: Binding(
            get: { Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }), displayedComponents: .hourAndMinute)
    }
}

struct GeneralSettings: View {
    let settings: SettingsStore

    var body: some View {
        Form {
            Section("Heart-rate zones") {
                Stepper(value: Binding(get: { settings.value.age ?? 0 },
                                       set: { v in settings.update { $0.age = v == 0 ? nil : v } }),
                        in: 0...100) {
                    Text("Age: \(settings.value.age.map(String.init) ?? "not set")")
                }
                Toggle("Use my own max heart rate", isOn: Binding(
                    get: { settings.value.maxHROverride != nil },
                    set: { on in settings.update { $0.maxHROverride = on ? ($0.zones?.maxHR ?? 190) : nil } }))
                if let max = settings.value.maxHROverride {
                    Stepper("Max HR: \(max) bpm", value: Binding(
                        get: { max }, set: { v in settings.update { $0.maxHROverride = v } }),
                            in: HeartRateZones.plausibleMaxHR)
                }
                if let zones = settings.value.zones {
                    let z2 = zones.range(of: .zone2)
                    Text("Zone 2 (easy): \(z2.lowerBound)–\(z2.upperBound) bpm. Estimated from 220 − age unless you set your own max.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Work hours") {
                MinuteOfDayPicker(title: "Start", minute: binding(settings, \.workHours.startMinute))
                MinuteOfDayPicker(title: "End", minute: binding(settings, \.workHours.endMinute))
                WeekdayPicker(days: binding(settings, \.workDays))
            }
            Section("Quiet hours") {
                MinuteOfDayPicker(title: "From", minute: binding(settings, \.quietHours.startMinute))
                MinuteOfDayPicker(title: "To", minute: binding(settings, \.quietHours.endMinute))
                Text("No nudges or reminders during quiet hours.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct WeekdayPicker: View {
    @Binding var days: Set<Int>

    var body: some View {
        HStack {
            Text("Work days")
            Spacer()
            ForEach(1...7, id: \.self) { day in
                let symbol = Calendar.current.veryShortWeekdaySymbols[day - 1]
                Toggle(symbol, isOn: Binding(
                    get: { days.contains(day) },
                    set: { on in if on { days.insert(day) } else { days.remove(day) } }))
                    .toggleStyle(.button)
                    .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
            }
        }
    }
}

struct NudgeSettings: View {
    let env: AppEnvironment
    private var settings: SettingsStore { env.settings }

    var body: some View {
        Form {
            Section {
                Toggle("Suggest a break when my heart rate stays high at my desk",
                       isOn: binding(settings, \.nudgeEnabled))
            } footer: {
                Text("Only during work hours, outside quiet hours, and never during a workout session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("When") {
                Stepper("At least \(settings.value.nudgeThresholdBPM) bpm above my resting heart rate",
                        value: binding(settings, \.nudgeThresholdBPM), in: 10...60, step: 5)
                Stepper("For \(settings.value.nudgeSustainedMinutes) minutes",
                        value: binding(settings, \.nudgeSustainedMinutes), in: 3...60)
                Stepper("At most once every \(settings.value.nudgeMinIntervalMinutes) minutes",
                        value: binding(settings, \.nudgeMinIntervalMinutes), in: 15...240, step: 15)
            }
            Section {
                Stepper("Resting heart rate: \(settings.value.fallbackRestingHR) bpm",
                        value: binding(settings, \.fallbackRestingHR), in: 35...100)
            } footer: {
                Text("Used until PulseBar has learned your resting heart rate from Google Health.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Send a test notification") {
                    Task {
                        _ = await env.notifier.requestAuthorization()
                        await env.notifier.post(id: "test", title: NudgeEngine.title,
                                                body: NudgeEngine.body(minutes: settings.value.nudgeSustainedMinutes))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
