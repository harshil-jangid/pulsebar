import PulseBarCore
import SwiftUI

/// Popover "Check-in": a ~10-second evening form (F6.1) and habit insights (F7).
/// Prefilled from your last check-in, so a typical night is one tap on Save.
struct CheckinView: View {
    let env: AppEnvironment
    @State private var checkin = Checkin(nightOf: Checkin.nightOf(Date()))
    @State private var savedNight: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tonight").font(.headline)
                Text(nightLabel).foregroundStyle(.secondary)
                Spacer()
                if savedNight == checkin.nightOf {
                    Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                }
            }
            row("Alcohol") {
                Picker("Alcohol", selection: $checkin.alcohol) {
                    Text("None").tag(Checkin.Alcohol.none)
                    Text("Some").tag(Checkin.Alcohol.some)
                    Text("A lot").tag(Checkin.Alcohol.aLot)
                }
            }
            row("Workout") {
                Picker("Workout", selection: $checkin.workout) {
                    ForEach(Checkin.Workout.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
            }
            if checkin.workout != .none {
                TextField("Type (e.g. run, gym)", text: Binding(
                    get: { checkin.workoutType ?? "" }, set: { checkin.workoutType = $0 }))
            }
            row("Worked from") {
                Picker("Worked from", selection: $checkin.location) {
                    Text("Office").tag(Checkin.Location.office)
                    Text("Home").tag(Checkin.Location.home)
                }
            }
            row("Stress") {
                Picker("Stress", selection: $checkin.stress) {
                    ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                }
                .accessibilityHint("1 is calm, 5 is very stressed")
            }
            HStack {
                Toggle("Late heavy meal", isOn: $checkin.lateHeavyMeal)
                Toggle("Caffeine after 3 pm", isOn: $checkin.caffeineAfter3pm)
                Toggle("Late screens", isOn: $checkin.lateScreens)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            let tags = env.settings.value.customTags.filter { !$0.hidden }
            if !tags.isEmpty {
                HStack {
                    ForEach(tags) { tag in
                        Toggle(tag.name, isOn: Binding(
                            get: { checkin.custom[tag.id] ?? false }, set: { checkin.custom[tag.id] = $0 }))
                    }
                }
                .toggleStyle(.button)
                .controlSize(.small)
            }
            TextField("Note (optional)", text: Binding(get: { checkin.note ?? "" }, set: { checkin.note = $0 }))
            HStack {
                Spacer()
                Button("Save") {
                    env.saveCheckin(checkin)
                    savedNight = checkin.nightOf
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            Divider()
            InsightsList(insights: env.insights)
        }
        .pickerStyle(.segmented)
        .onAppear(perform: load)
    }

    private var nightLabel: String {
        LocalDay.parse(checkin.nightOf)?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) ?? ""
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(title).frame(width: 84, alignment: .leading)
            content().labelsHidden()
        }
    }

    private func load() {
        let night = Checkin.nightOf(Date())
        if let existing = try? env.db.checkin(nightOf: night) {
            checkin = existing
            savedNight = night
        } else if var last = try? env.db.latestCheckin() {
            // Habits repeat: start from last time, but not the note or tonight's specifics.
            last.nightOf = night
            last.note = nil
            last.alcohol = .none
            last.workout = .none
            last.workoutType = nil
            checkin = last
        }
    }
}

struct InsightsList: View {
    let insights: [HabitInsight]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Patterns so far").font(.headline)
            if insights.isEmpty {
                Text("Patterns appear once you have at least \(HabitInsights.minimumPerGroup) nights with and \(HabitInsights.minimumPerGroup) without a habit.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(insights.prefix(5)) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(i.sentence).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Text("\(i.confidence.rawValue.capitalized) pattern").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text("These are associations in your own data, not proof of cause.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
