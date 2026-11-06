import PulseBarCore
import ServiceManagement
import SwiftUI

/// Settings → Data (F9, F1.3 data folder).
struct DataSettings: View {
    let env: AppEnvironment
    @State private var confirmDelete = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("Where your data lives") {
                LabeledContent("Data folder") {
                    Text(AppDatabase.defaultDirectory.path(percentEncoded: false)).textSelection(.enabled).font(.callout.monospaced())
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppDatabase.defaultURL]) }
                Text("Only this Mac. File readable by your user only. Google tokens are in your Keychain. Turn on FileVault (System Settings → Privacy & Security) so the disk is encrypted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Export") {
                Button("Export all data (CSV + JSON)…") { export() }
                Text("One CSV per table plus a single pulsebar.json. Tokens are never exported.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Delete") {
                Button("Delete all data…", role: .destructive) { confirmDelete = true }
                Text("Removes everything PulseBar stored, signs out of Google (revoking access) and deletes PulseBar's Keychain items. Live heart-rate samples older than 90 days are already reduced to session summaries automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.callout) }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all PulseBar data?", isPresented: $confirmDelete) {
            Button("Delete everything", role: .destructive) {
                Task {
                    await env.deleteAllData()
                    message = "All data deleted."
                }
            }
        } message: {
            Text("This can't be undone. Consider exporting first.")
        }
    }

    private func export() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        guard panel.runModal() == .OK, let base = panel.url else { return }
        let folder = base.appending(path: "PulseBar Export \(LocalDay.string(Date()))")
        do {
            let files = try env.db.export(to: folder)
            message = "Exported \(files.count) files."
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }
}

/// Settings → About: version, disclaimer, licenses, updates (F10), welcome again.
struct AboutSettings: View {
    let env: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                LabeledContent("PulseBar", value: "Version \(PulseBarCore.version)")
                Link("Source code on GitHub", destination: URL(string: "https://github.com/harshil-jangid/pulsebar")!)
            }
            Section("Health disclaimer") {
                Text("PulseBar is not a medical device and does not give medical advice. It doesn't diagnose anything. Readiness and habit patterns are simple personal heuristics. Consult a doctor before making major changes to your training.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Updates") {
                Toggle("Check GitHub for new versions (at most once a day)", isOn: binding(env.settings, \.updateCheckEnabled))
                if let update = env.availableUpdate {
                    Link("Version \(update.version) is available. Open the download page", destination: update.url)
                } else {
                    Button("Check now") { env.checkForUpdates(force: true) }
                        .disabled(!env.settings.value.updateCheckEnabled)
                }
                Text("PulseBar never downloads or installs updates by itself.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("No accounts, no analytics, no tracking. Network use: Google's sign-in and Health API (only if you connect Google) and the optional GitHub update check.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Open-source licenses") {
                Text("PulseBar: MIT License.\nGRDB.swift (SQLite toolkit) by Gwendal Roué: MIT License.")
                    .font(.callout)
            }
            Section {
                Button("Show the welcome screens again") { NSApp.activate(); openWindow(id: OnboardingView.windowID) }
            }
        }
        .formStyle(.grouped)
    }
}

/// Launch at login via SMAppService (macOS 13+). Registers the app itself; no helper.
struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        Toggle("Open PulseBar when I log in", isOn: Binding(get: { enabled }, set: { on in
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                error = nil
            } catch {
                self.error = "macOS didn't allow this: \(error.localizedDescription). Move PulseBar to Applications and try again."
            }
            enabled = SMAppService.mainApp.status == .enabled
        }))
        if let error { Text(error).font(.caption).foregroundStyle(.orange) }
    }
}
