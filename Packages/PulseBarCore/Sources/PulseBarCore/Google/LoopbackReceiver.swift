import Foundation
import Network

/// One-shot HTTP listener on 127.0.0.1 (random port) that receives the OAuth
/// redirect from the browser and then shuts down.
public final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "io.github.pulsebar.loopback")
    private var continuation: CheckedContinuation<URL, Error>?
    /// Callback that arrived before anyone was waiting for it.
    private var early: URL?
    private var finished = false
    /// Touched only on `queue` (where all listener callbacks run).
    private var startResumed = false

    public init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
    }

    /// Starts listening and returns the redirect URI to give Google.
    public func start() async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            listener.stateUpdateHandler = { [self] state in
                guard !startResumed else { return }
                switch state {
                case .ready:
                    startResumed = true
                    cont.resume(returning: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)/")
                case .failed(let error):
                    startResumed = true
                    cont.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: queue)
        }
    }

    /// Waits for the browser redirect (default 5 minutes).
    public func waitForCallback(timeout: Duration = .seconds(300)) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    self.queue.async {
                        if let early = self.early { cont.resume(returning: early) } else { self.continuation = cont }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CancellationError()
            }
            defer { group.cancelAll(); self.stop() }
            return try await group.next()!
        }
    }

    public func stop() {
        queue.async {
            self.listener.cancel()
            if !self.finished {
                self.finished = true
                self.continuation?.resume(throwing: CancellationError())
                self.continuation = nil
            }
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let line = request.split(separator: "\r\n").first else { conn.cancel(); return }
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET",
                  let url = URL(string: "http://127.0.0.1\(parts[1])") else { conn.cancel(); return }
            // Ignore favicon and other stray requests.
            let isCallback = url.query?.contains("state=") ?? false
            let html = isCallback
                ? "<html><body style='font-family:-apple-system;padding:3em'><h2>PulseBar is connected.</h2><p>You can close this tab and return to PulseBar.</p></body></html>"
                : ""
            let response = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
            if isCallback, !self.finished {
                self.finished = true
                if let c = self.continuation { c.resume(returning: url) } else { self.early = url }
                self.continuation = nil
            }
        }
    }
}
