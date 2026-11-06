import PulseBarCore
import SwiftUI

/// Settings → Goal: goal label/date and free-text intentions (F1.2), morning card (F4.3).
struct GoalSettings: View {
    let env: AppEnvironment
    @State private var label = ""
    @State private var date = Date().addingTimeInterval(90 * 86400)
    @State private var intentions = ""

    var body: some View {
        Form {
            Section("Your goal") {
                TextField("Name", text: $label, prompt: Text("e.g. Wedding"))
                DatePicker("Date", selection: $date, in: Date()..., displayedComponents: .date)
                TextField("Intentions (optional)", text: $intentions, prompt: Text("e.g. lower resting HR, sleep 7 h"), axis: .vertical)
                    .lineLimit(2...4)
                Button("Save goal") {
                    var goal = env.goal ?? Goal(label: label, goalDate: LocalDay.string(date))
                    goal.label = label.isEmpty ? "My goal" : label
                    goal.goalDate = LocalDay.string(date)
                    goal.intentions = intentions.isEmpty ? nil : intentions
                    env.saveGoal(goal)
                }
                .disabled(label.isEmpty)
                if let snap = env.goal?.startSnapshot {
                    Text("Starting baseline fixed from \(snap.fromDate) to \(snap.toDate).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Morning readiness") {
                Toggle("Notify me with today's readiness", isOn: binding(env.settings, \.morningReadinessEnabled))
                MinuteOfDayPicker(title: "At", minute: Binding(
                    get: { env.settings.value.morningReadinessMinute },
                    set: { v in env.settings.update { $0.morningReadinessMinute = v }; env.scheduleMorningCheck() }))
                Text("Sent once today's sleep data has synced, never during quiet hours.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if let g = env.goal {
                label = g.label
                date = LocalDay.parse(g.goalDate) ?? date
                intentions = g.intentions ?? ""
            }
        }
    }
}
