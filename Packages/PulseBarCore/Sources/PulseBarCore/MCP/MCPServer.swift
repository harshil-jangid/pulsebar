import Foundation
import GRDB

/// Minimal, dual-era MCP server over newline-delimited JSON-RPC (stdio).
///
/// Verified against the MCP specification (modelcontextprotocol.io):
/// - **Modern (2026-07-28):** stateless; every request carries
///   `_meta["io.modelcontextprotocol/protocolVersion"]` and `…/clientCapabilities`;
///   `server/discover` is mandatory; results carry `resultType`.
/// - **Legacy (2025-11-25 and earlier):** `initialize` handshake, then requests.
/// Only the tools feature is implemented. All tools are read-only (F8).
public final class MCPServer {
    public static let modernVersions = ["2026-07-28"]
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static var supportedVersions: [String] { modernVersions + legacyVersions }
    static let metaVersion = "io.modelcontextprotocol/protocolVersion"
    static let metaCapabilities = "io.modelcontextprotocol/clientCapabilities"

    public static let instructions = """
        Read-only access to the user's PulseBar data on this Mac: daily resting heart rate, sleep HRV, sleep, \
        steps, readiness, goal progress, evening check-ins, habit associations and live heart-rate session \
        summaries. Dates are ISO-8601 (YYYY-MM-DD) in the user's local time zone; every response states units. \
        Not medical advice: describe patterns as associations, never diagnoses.
        """

    private let tools: ConnectorTools
    /// Set by a legacy `initialize`; legacy semantics are scoped to this stdio process.
    private(set) var legacyVersion: String?

    public init(reader: (any DatabaseReader)?, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = Date.init) {
        tools = ConnectorTools(reader: reader, calendar: calendar, now: now)
    }

    /// Handles one line of input; returns one line of output, or nil for notifications.
    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(),
                                "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let method = obj["method"] as? String else {
            return Self.error(obj["id"], -32600, "Invalid request")
        }
        guard let id = obj["id"], !(id is NSNull) else { return nil } // notification: never answer
        let params = obj["params"] as? [String: Any] ?? [:]
        let meta = params["_meta"] as? [String: Any]

        // Legacy handshake.
        if method == "initialize" {
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.legacyVersions.contains(requested) ? requested : Self.legacyVersions[0]
            legacyVersion = version
            return Self.result(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": Self.serverInfo,
                "instructions": Self.instructions,
            ])
        }

        // Decide era for this request.
        let modern: Bool
        if let requested = meta?[Self.metaVersion] as? String {
            guard Self.modernVersions.contains(requested) else {
                return Self.error(id, -32022, "Unsupported protocol version",
                                  data: ["supported": Self.supportedVersions, "requested": requested])
            }
            guard meta?[Self.metaCapabilities] is [String: Any] else {
                return Self.error(id, -32602, "Missing required _meta field \(Self.metaCapabilities)")
            }
            modern = true
        } else if legacyVersion != nil {
            modern = false
        } else if method == "ping" {
            modern = false
        } else {
            return Self.error(id, -32602, "Missing required _meta field \(Self.metaVersion). Supported versions: \(Self.supportedVersions.joined(separator: ", "))")
        }

        func ok(_ result: [String: Any]) -> String {
            var r = result
            if modern {
                r["resultType"] = "complete"
                r["_meta"] = ["io.modelcontextprotocol/serverInfo": Self.serverInfo]
            }
            return Self.result(id, r)
        }

        switch method {
        case "server/discover":
            return ok(["supportedVersions": Self.supportedVersions,
                       "capabilities": ["tools": ["listChanged": false]],
                       "instructions": Self.instructions])
        case "ping":
            return ok([:])
        case "tools/list":
            return ok(["tools": ConnectorTools.definitions])
        case "tools/call":
            guard let name = params["name"] as? String else { return Self.error(id, -32602, "Missing tool name") }
            guard ConnectorTools.names.contains(name) else { return Self.error(id, -32602, "Unknown tool: \(name)") }
            let args = params["arguments"] as? [String: Any] ?? [:]
            switch tools.call(name, args) {
            case .success(let payload):
                let text = Self.encode(payload) ?? "{}"
                return ok(["content": [["type": "text", "text": text]], "structuredContent": payload, "isError": false])
            case .failure(let error):
                return ok(["content": [["type": "text", "text": error.message]], "isError": true])
            }
        default:
            return Self.error(id, -32601, "Method not found: \(method)")
        }
    }

    static var serverInfo: [String: Any] { ["name": "pulsebar-mcp", "title": "PulseBar", "version": PulseBarCore.version] }

    static func result(_ id: Any, _ result: [String: Any]) -> String {
        encode(["jsonrpc": "2.0", "id": id, "result": result]) ?? ""
    }

    static func error(_ id: Any?, _ code: Int, _ message: String, data: [String: Any]? = nil) -> String {
        var err: [String: Any] = ["code": code, "message": message]
        if let data { err["data"] = data }
        return encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": err]) ?? ""
    }

    /// Single-line JSON (stdio framing forbids embedded newlines; JSONSerialization escapes them).
    static func encode(_ obj: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
