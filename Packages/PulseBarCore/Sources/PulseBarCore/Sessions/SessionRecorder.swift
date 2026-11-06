import Foundation
import GRDB
import Observation
import os

/// Turns the live heart-rate stream into stored sessions (spec F2.4).
///
/// - A **desk** session starts automatically when a device connects and ends
///   when it disconnects (or after a gap longer than `maxGap`).
/// - A **workout** session is started/stopped manually; it pauses desk nudges.
/// - Samples are buffered and written in small batches, so a crash loses at
///   most a few seconds; `recoverOpenSessions()` tidies up on next launch.
@MainActor
@Observable
public final class SessionRecorder {
    public private(set) var current: LiveSession?
    public var isWorkout: Bool { current?.kind == .workout }

    @ObservationIgnored private let db: AppDatabase
    @ObservationIgnored private var bufferSamples: [(Date, Int)] = []
    @ObservationIgnored private var bufferRR: [(Date, Double)] = []
    @ObservationIgnored private var lastFlush = Date.distantPast
    @ObservationIgnored private var lastSampleAt: Date?
    @ObservationIgnored private var deviceName: String?
    @ObservationIgnored private let log = Logger(subsystem: "io.github.pulsebar", category: "Sessions")

    public let flushEvery: TimeInterval
    public let maxGap: TimeInterval

    public init(db: AppDatabase, flushEvery: TimeInterval = 15, maxGap: TimeInterval = 300) {
        self.db = db
        self.flushEvery = flushEvery
        self.maxGap = maxGap
    }

    public func handle(_ event: HeartRateSourceEvent) {
        switch event {
        case .connection(.connected(let name)):
            deviceName = name
        case .connection(.idle), .availability(.poweredOff), .availability(.unauthorized):
            endSession(at: lastSampleAt ?? Date())
        case .measurement(let m, let date):
            record(m, at: date)
        default:
            break
        }
    }

    public func record(_ m: HeartRateMeasurement, at date: Date) {
        guard m.hasValidContact else { return }
        if let last = lastSampleAt, date.timeIntervalSince(last) > maxGap {
            let kind = current?.kind ?? .desk
            endSession(at: last)
            startSession(kind: kind, at: date)
        }
        if current == nil { startSession(kind: .desk, at: date) }
        lastSampleAt = date
        bufferSamples.append((date, m.bpm))
        bufferRR.append(contentsOf: m.rrIntervalsMs.map { (date, $0) })
        if date.timeIntervalSince(lastFlush) >= flushEvery { flush() }
    }

    public func startWorkout(at date: Date = Date()) {
        endSession(at: date)
        startSession(kind: .workout, at: date)
    }

    public func endWorkout(at date: Date = Date()) {
        guard isWorkout else { return }
        endSession(at: date)
        // The next measurement starts a new desk session automatically.
    }

    /// Writes buffered samples. Call on quit too.
    public func flush() {
        guard let id = current?.id, !bufferSamples.isEmpty || !bufferRR.isEmpty else { return }
        let samples = bufferSamples, rr = bufferRR
        bufferSamples.removeAll(keepingCapacity: true)
        bufferRR.removeAll(keepingCapacity: true)
        lastFlush = samples.last?.0 ?? Date()
        do {
            try db.writer.write { db in
                let s = try db.makeStatement(sql: "INSERT INTO live_samples (session_id, ts, bpm) VALUES (?, ?, ?)")
                for (ts, bpm) in samples { try s.execute(arguments: [id, ts, bpm]) }
                let r = try db.makeStatement(sql: "INSERT INTO live_rr (session_id, ts, rr_ms) VALUES (?, ?, ?)")
                for (ts, ms) in rr { try r.execute(arguments: [id, ts, ms]) }
            }
        } catch {
            log.error("Failed to save samples: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func endSession(at date: Date) {
        guard let id = current?.id else { current = nil; return }
        flush()
        do { try db.finalizeSession(id, end: date) } catch {
            log.error("Failed to close session: \(error.localizedDescription, privacy: .public)")
        }
        current = nil
        lastSampleAt = nil
    }

    private func startSession(kind: SessionKind, at date: Date) {
        var session = LiveSession(start: date, kind: kind, deviceName: deviceName)
        do {
            try db.writer.write { try session.insert($0) }
            current = session
            lastFlush = date
        } catch {
            log.error("Failed to start session: \(error.localizedDescription, privacy: .public)")
        }
    }
}
