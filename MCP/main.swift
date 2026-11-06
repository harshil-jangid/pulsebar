import Foundation
import PulseBarCore

// pulsebar-mcp: read-only Claude connector over stdio (built in M6).
// M0 placeholder proving the target builds and links PulseBarCore.
// stdout is reserved for MCP JSON-RPC, so human messages go to stderr.
FileHandle.standardError.write(Data("pulsebar-mcp \(PulseBarCore.version): not implemented yet (M6)\n".utf8))
exit(0)
