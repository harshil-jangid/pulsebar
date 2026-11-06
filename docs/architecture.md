# Architecture

```
┌──────────────── PulseBar.app (SwiftUI, menu bar, macOS 26+) ─────────────────┐
│ App/  MenuBarExtra popover (Now · Today · Progress · Check-in), Settings,     │
│       onboarding. AppEnvironment owns and wires every service.                │
│   │                                                                            │
│ Packages/PulseBarCore (no UI, unit-tested)                                     │
│   ├─ LiveHR     CoreBluetooth 0x180D/0x2A37 → HeartRateMeasurement parser,     │
│   │             LiveHeartRateModel, reconnect backoff, demo source             │
│   ├─ Sessions   SessionRecorder (desk/workout, batched writes, crash recovery) │
│   ├─ Nudge      NudgeEngine (pure rules) + Notifier (UserNotifications)        │
│   ├─ Google     OAuth PKCE + loopback, Keychain, GoogleHealthClient, sync      │
│   ├─ Metrics    baselines (median/MAD), readiness, trends, goal, live RMSSD    │
│   ├─ Checkins   check-ins, habit insights                                      │
│   ├─ MCP        dual-era MCP server + 8 read-only tools                        │
│   └─ Store      GRDB/SQLite, versioned migrations, settings, export/delete     │
└──────────────────────────────────────────────────▲────────────────────────────┘
                     read-only SQLite connection    │ stdio (JSON-RPC)
              Contents/MacOS/pulsebar-mcp ──────────┘◄──── Claude desktop
```

## Key decisions

| Decision | Why |
|---|---|
| **One Swift package for all logic** | The app and `pulsebar-mcp` share it; it builds and tests with `swift test`, no UI needed. |
| **SQLite via GRDB** (not SwiftData) | The MCP server needs a stable, documented schema and a read-only connection. |
| **XcodeGen** (`project.yml`) | A readable, reviewable project definition instead of a machine-written `.pbxproj`. |
| **Protocols at every hardware/network edge** (`HeartRateSource`, `HTTPTransport`, `SecretStore`, `Notifier`) | Tests replay fixtures instead of needing a strap, Google account or Keychain. |
| **Event-driven, no polling** | BLE notifications drive everything; reconnects use CoreBluetooth's never-timing-out pending connect; one-shot timers for the morning card; a coalesced 3-hour sync timer. |
| **Own MCP implementation** | The 2026-07-28 MCP spec is stateless (per-request `_meta`); the Swift SDK covered only the older handshake. A ~200-line dual-era server supports both. |
| **Reconcile + client-side sums for steps** | Google documents that `reconcile` de-duplicates sources; it doesn't say that for roll-ups. |

## Database (migrations in `AppDatabase.migrator`)

| Migration | Tables |
|---|---|
| v1 | `settings` (key/value; app settings as one JSON document) |
| v2 | `live_sessions`, `live_samples`, `live_rr` (RR intervals in their own table: one packet can carry several) |
| v3 | `daily_metrics`, `workouts`, `sync_state` |
| v4 | `goal` (single row, frozen start snapshot) |
| v5 | `checkins` (one row per tag per night) |

Shipped migrations are never edited; changes always come as a new migration.

## Testing

`xcodebuild test` runs ~100 tests: BLE parsing for every flag combination, baselines/readiness with worked
examples, nudge rules, sessions and crash recovery, Google OAuth (RFC 7636 vector) and sync against recorded
fixtures (idempotency, paging, retries, re-auth), habit statistics, export/delete/retention, and the MCP server
in both protocol eras, including a byte-for-byte check that the connector never changes the database.

Run with `-demo` for simulated data; DEBUG builds also accept `-snapshot <dir>` to render every screen to PNG.
