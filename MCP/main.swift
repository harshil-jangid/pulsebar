import Foundation
import PulseBarCore

// pulsebar-mcp: read-only Claude connector (MCP over stdio), shipped inside
// PulseBar.app/Contents/MacOS/. It opens the PulseBar database READ-ONLY
// (SQLite enforces it) and makes no network calls.
//
// Usage: pulsebar-mcp [--db /path/to/pulsebar.sqlite]
// stdout carries only MCP messages; diagnostics go to stderr.

var dbURL = AppDatabase.defaultURL
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--db"), i + 1 < args.count {
    dbURL = URL(fileURLWithPath: args[i + 1])
}

let reader = FileManager.default.fileExists(atPath: dbURL.path) ? try? AppDatabase.openReadOnly(at: dbURL) : nil
if reader == nil {
    FileHandle.standardError.write(Data("pulsebar-mcp: no database at \(dbURL.path); tools will ask the user to open PulseBar.\n".utf8))
}
let server = MCPServer(reader: reader)

// Newline-delimited JSON-RPC until stdin closes (the client's shutdown signal).
while let line = readLine(strippingNewline: true) {
    guard !line.allSatisfy(\.isWhitespace) else { continue }
    if let response = server.handle(line: line) {
        FileHandle.standardOutput.write(Data((response + "\n").utf8))
    }
}
