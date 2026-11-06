import PulseBarCore
import SwiftUI

/// Settings → Claude (F8.4): opt-in, the exact Claude desktop config snippet,
/// steps, a self-test, and ready-made prompts. PulseBar never edits Claude's files.
struct ClaudeSettings: View {
    let env: AppEnvironment
    @State private var copied = false
    @State private var testResult: String?

    static var serverPath: String {
        Bundle.main.url(forAuxiliaryExecutable: "pulsebar-mcp")?.path
            ?? "/Applications/PulseBar.app/Contents/MacOS/pulsebar-mcp"
    }

    static var snippet: String {
        """
        {
          "mcpServers": {
            "pulsebar": {
              "command": "\(serverPath)"
            }
          }
        }
        """
    }

    static let prompts = [
        "Give me my weekly review.",
        "Plan this week's training from my recovery.",
        "Why was my HRV low on Tuesday?",
        "How am I progressing toward my goal?",
        "Which of my habits line up with better sleep HRV?",
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Allow Claude to read my PulseBar data", isOn: binding(env.settings, \.claudeAccessEnabled))
                Text("""
                    When you ask Claude about your health data, Claude (made by Anthropic) reads it through a small \
                    read-only program inside PulseBar. What Claude reads becomes part of that conversation and is \
                    handled under your Claude account's terms. PulseBar's connector can't change or delete anything, \
                    and makes no network calls itself. Turn this off any time; Claude will then be told access is off.
                    """)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Connect Claude desktop") {
                step(1, "In Claude desktop, open the Claude menu → Settings… → Developer → Edit Config.")
                step(2, "Add this to claude_desktop_config.json (merge it if you already have mcpServers):")
                Text(Self.snippet).font(.caption.monospaced()).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Button(copied ? "Copied" : "Copy snippet") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.snippet, forType: .string)
                        copied = true
                    }
                    Button("Show Claude's config folder") {
                        let dir = URL.applicationSupportDirectory.appending(path: "Claude")
                        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: dir.path) ? dir : .applicationSupportDirectory)
                    }
                }
                step(3, "Quit Claude completely and reopen it. “pulsebar” then appears under Connectors.")
                Text("If you move PulseBar.app, update the path in the snippet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Check the connector") {
                HStack {
                    Button("Test connector") { Task { testResult = await Self.selfTest() } }
                    if let testResult { Text(testResult).font(.callout) }
                }
            }
            Section("Things to ask") {
                ForEach(Self.prompts, id: \.self) { Text("“\($0)”").textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(n).").monospacedDigit().foregroundStyle(.secondary)
            Text(text)
        }
    }

    /// Runs the bundled server exactly like Claude would and asks it to list its tools.
    static func selfTest() async -> String {
        let path = serverPath
        guard FileManager.default.isExecutableFile(atPath: path) else { return "pulsebar-mcp not found in the app bundle." }
        return await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            let input = Pipe(), output = Pipe()
            p.standardInput = input
            p.standardOutput = output
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return "Couldn't start pulsebar-mcp: \(error.localizedDescription)" }
            let meta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#
            input.fileHandleForWriting.write(Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\(meta)}}\n".utf8))
            try? input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationReason == .uncaughtSignal {
                // Gatekeeper kills helpers inside a still-quarantined download (see README → Install).
                return "macOS blocked the connector. See README → “If the Claude connector is blocked”."
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tools = (obj["result"] as? [String: Any])?["tools"] as? [Any] else {
                return "The connector didn't answer as expected."
            }
            return "✓ Working: \(tools.count) read-only tools ready."
        }.value
    }
}
