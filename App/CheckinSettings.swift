import PulseBarCore
import SwiftUI

/// Settings → Check-in: reminder time (F6.1) and custom tags (F6.2).
struct CheckinSettings: View {
    let env: AppEnvironment
    @State private var newTag = ""

    var body: some View {
        Form {
            Section("Reminder") {
                Toggle("Remind me to check in each evening", isOn: Binding(
                    get: { env.settings.value.checkinReminderEnabled },
                    set: { v in env.settings.update { $0.checkinReminderEnabled = v }; env.scheduleCheckinReminder() }))
                MinuteOfDayPicker(title: "At", minute: Binding(
                    get: { env.settings.value.checkinReminderMinute },
                    set: { v in env.settings.update { $0.checkinReminderMinute = v }; env.scheduleCheckinReminder() }))
                if env.settings.value.quietHours.contains(
                    Calendar.current.date(bySettingHour: env.settings.value.checkinReminderMinute / 60,
                                          minute: env.settings.value.checkinReminderMinute % 60, second: 0, of: Date())!) {
                    Text("This time is inside your quiet hours, so no reminder will be sent.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Your own tags") {
                ForEach(env.settings.value.customTags) { tag in
                    HStack {
                        TextField("Name", text: Binding(get: { tag.name }, set: { name in
                            env.settings.update { s in
                                if let i = s.customTags.firstIndex(of: tag) { s.customTags[i].name = name }
                            }
                        }))
                        Toggle("Hidden", isOn: Binding(get: { tag.hidden }, set: { hidden in
                            env.settings.update { s in
                                if let i = s.customTags.firstIndex(of: tag) { s.customTags[i].hidden = hidden }
                            }
                        }))
                    }
                }
                HStack {
                    TextField("New yes/no tag", text: $newTag, prompt: Text("e.g. Meditated"))
                    Button("Add") {
                        let name = newTag.trimmingCharacters(in: .whitespaces)
                        env.settings.update { $0.customTags.append(CustomTag(name: name)) }
                        newTag = ""
                    }
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Hiding a tag keeps its history but removes it from the form and insights.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
