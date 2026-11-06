import PulseBarCore
import SwiftUI

/// First-run flow (F1.1): what PulseBar does, health disclaimer, data sources,
/// goal, notification permission. Shown once; reopen from Settings → About.
struct OnboardingView: View {
    let env: AppEnvironment
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @State private var page = 0
    @State private var acceptedDisclaimer = false
    @State private var useGoogle = false
    @State private var goalLabel = ""
    @State private var goalDate = Date().addingTimeInterval(120 * 86400)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch page {
            case 0: welcome
            case 1: disclaimer
            case 2: sources
            default: goal
            }
            Spacer()
            HStack {
                if page > 0 { Button("Back") { page -= 1 } }
                Spacer()
                Text("\(page + 1) of 4").font(.caption).foregroundStyle(.secondary)
                Button(page == 3 ? "Finish" : "Continue") { next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(page == 1 && !acceptedDisclaimer)
            }
        }
        .padding(28)
        .frame(width: 520, height: 420)
        .onAppear { NSApp.activate() }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Welcome to PulseBar", systemImage: "heart.fill").font(.largeTitle.weight(.semibold))
            Text("A quiet menu-bar companion for desk workers who want better cardiovascular fitness and recovery: HRV up, resting heart rate down, toward a date that matters to you.")
            Label("Live heart rate from any Bluetooth heart-rate device", systemImage: "antenna.radiowaves.left.and.right")
            Label("Morning readiness vs. your own baseline", systemImage: "sunrise")
            Label("Progress toward your goal date", systemImage: "chart.line.uptrend.xyaxis")
            Label("Everything stays on this Mac. No accounts, no tracking.", systemImage: "lock")
        }
    }

    private var disclaimer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Before you start", systemImage: "cross.case").font(.title.weight(.semibold))
            Text("PulseBar is **not a medical device** and does not give medical advice. It doesn't diagnose anything and can't detect heart conditions. Readiness scores are a simple personal heuristic.")
            Text("Consult a doctor before making major changes to your training, especially if you have a heart condition or symptoms such as chest pain, dizziness or shortness of breath.")
            Toggle("I understand", isOn: $acceptedDisclaimer)
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Your data sources", systemImage: "point.3.connected.trianglepath.dotted").font(.title.weight(.semibold))
            Picker("Data sources", selection: $useGoogle) {
                Text("Live heart rate only").tag(false)
                Text("Live heart rate + Google Health history").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(useGoogle
                 ? "After setup, open Settings → Google to connect your own free Google client. Readiness and progress charts need it."
                 : "You can connect Google Health later in Settings.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var goal: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("What are you training for?", systemImage: "flag.checkered").font(.title.weight(.semibold))
            TextField("Goal", text: $goalLabel, prompt: Text("e.g. Wedding"))
            DatePicker("Date", selection: $goalDate, in: Date()..., displayedComponents: .date)
            Text("Optional. PulseBar shows a countdown and your progress from day one, with no prescribed targets.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func next() {
        guard page == 3 else { page += 1; return }
        if !goalLabel.isEmpty { env.saveGoal(Goal(label: goalLabel, goalDate: LocalDay.string(goalDate))) }
        env.settings.update { $0.onboardingCompleted = true; $0.useGoogleHealth = useGoogle }
        Task { await env.prepareNotifications() }
        dismissWindow(id: OnboardingView.windowID)
        if useGoogle { NSApp.activate(); openSettings() }
    }

    static let windowID = "onboarding"
}
