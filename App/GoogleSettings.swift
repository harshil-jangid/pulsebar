import PulseBarCore
import SwiftUI

/// Settings → Google: bring-your-own OAuth client setup (F3.1), the in-app
/// disclosure Google's policy requires right before consent (F1.4), and status.
struct GoogleSettings: View {
    let env: AppEnvironment
    private var google: GoogleSync { env.google }

    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var agreed = false
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        Form {
            statusSection
            if !google.isConnected || google.status == .reauthRequired {
                setupGuide
                credentials
                disclosure
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .onAppear { clientID = env.settings.value.googleClientID ?? "" }
    }

    // MARK: Status

    private var statusSection: some View {
        Section("Google Health") {
            HStack {
                statusLabel
                Spacer()
                if google.isConnected {
                    Button("Sync now") { Task { await google.sync() } }
                        .disabled({ if case .syncing = google.status { true } else { false } }())
                    Button("Disconnect", role: .destructive) { Task { await google.disconnect() } }
                }
            }
            if let last = google.lastSuccess {
                Text("Last synced \(last, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch google.status {
        case .notConnected: Label("Not connected", systemImage: "link.badge.plus")
        case .idle: Label("Connected", systemImage: "checkmark.circle")
        case .syncing(let type): Label("Syncing \(type)…", systemImage: "arrow.triangle.2.circlepath")
        case .reauthRequired: Label("Google sign-in expired. Reconnect below.", systemImage: "exclamationmark.arrow.circlepath")
        case .error(let message): Label(message, systemImage: "exclamationmark.triangle")
        }
    }

    // MARK: Setup guide

    private var setupGuide: some View {
        Section("1 · Create your own free Google client (about 5 minutes)") {
            step(1, "Install the Google Health app on your phone and sign in with the Google account you'll use here.", nil)
            step(2, "Create a Google Cloud project.", "https://console.cloud.google.com/projectcreate")
            step(3, "Enable the Google Health API in that project.", "https://console.developers.google.com/apis/library/health.googleapis.com")
            step(4, "OAuth consent screen → Audience: User type External, status Testing. Under Test users, add your own email.", "https://console.developers.google.com/auth/audience")
            step(5, "Data Access → Add or remove scopes → add these three read-only scopes:", "https://console.developers.google.com/auth/scopes")
            ForEach(GoogleDataType.scopes, id: \.self) { scope in
                Text(scope).font(.caption.monospaced()).textSelection(.enabled)
            }
            step(6, "Credentials → Create credentials → OAuth client ID → Application type: Desktop app. Copy the Client ID and Client secret below.", "https://console.developers.google.com/apis/credentials")
            Text("While your project is in Testing, Google ends the sign-in after 7 days. PulseBar will then show “Reconnect Google”; your data stays on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func step(_ n: Int, _ text: String, _ link: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(n).").monospacedDigit().foregroundStyle(.secondary)
            Text(text)
            Spacer()
            if let link, let url = URL(string: link) {
                Link("Open", destination: url)
            }
        }
    }

    // MARK: Credentials + disclosure + consent

    private var credentials: some View {
        Section("2 · Paste your client") {
            TextField("Client ID", text: $clientID, prompt: Text("…apps.googleusercontent.com"))
            SecureField("Client secret", text: $clientSecret)
            Text("Stored in your Mac's Keychain. Desktop-app secrets aren't truly secret, but we keep them there anyway.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var disclosure: some View {
        Section("3 · What PulseBar will read") {
            VStack(alignment: .leading, spacing: 6) {
                Text("PulseBar reads only these from Google Health, only to show them to you on this Mac:")
                ForEach(GoogleDataType.allCases, id: \.self) { type in
                    Label(type.disclosure, systemImage: "checkmark").font(.callout)
                }
                Text("""
                    Your data is stored only on this Mac (~/Library/Application Support/PulseBar). It is never sent to \
                    PulseBar's developers or any server. PulseBar never writes to Google Health. If you later turn on the \
                    Claude connector, Claude can read it only when you ask. PulseBar's use of Google Health data complies \
                    with the Google Health API Developer and User Data Policy, including its Limited Use requirements. \
                    You can disconnect and delete everything at any time.
                    """)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("I understand and agree", isOn: $agreed)
            Button(google.status == .reauthRequired ? "Reconnect Google" : "Connect Google") { connect() }
                .buttonStyle(.borderedProminent)
                .disabled(!agreed || clientID.isEmpty || working)
        }
    }

    private func connect() {
        working = true
        errorText = nil
        let secret = clientSecret.isEmpty ? nil : clientSecret
        Task {
            defer { working = false }
            do {
                try await google.connect(clientID: clientID, clientSecret: secret) { NSWorkspace.shared.open($0) }
            } catch GoogleAuthError.userDenied {
                errorText = "Google sign-in was cancelled."
            } catch is CancellationError {
                errorText = "Timed out waiting for Google sign-in. Try again."
            } catch {
                errorText = "Couldn't connect: \(error.localizedDescription)"
            }
        }
    }
}
