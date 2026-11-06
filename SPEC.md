# PulseBar: product & build spec

> Working name: rename freely. This file is the source of truth for building the app with Claude Code.
> Owner: Harshil. Status: v1 spec, 2026-11-06.

---

## 0. Instructions for Claude Code (read first)

1. Build in the **milestones in §9**, in order. After each milestone: run the tests, summarize what changed, list anything unverified, and **stop for my review** before starting the next.
2. **Verify, don't guess.** Anything listed in §11 (Open questions) must be checked against official docs or real-device testing before code depends on it. If something can't be verified, say so and build it behind an abstraction with a clear TODO.
3. **Everything must stay free:** no paid services, no paid Apple Developer account, no servers, no paid APIs, no telemetry/analytics vendors.
4. **Official interfaces only.** Use only the Google Health API (official REST, with the user's OAuth consent) and the standard Bluetooth Heart Rate Service. **Never** use private Fitbit/Google protocols, never write to the device, never touch firmware, pairing keys or the Google Health app's connection.
5. Prefer small, readable, well-tested code over cleverness. Keep dependencies minimal and permissively licensed (MIT/Apache-2.0/BSD).

---

## 1. Vision

A free, open-source **macOS menu-bar app** that helps people who sit at a desk all day improve their cardiovascular fitness and recovery (**HRV up, resting heart rate down**) toward a personal goal date, using their own wearable data.

- **Live heart rate** from any wearable or strap that broadcasts the standard Bluetooth heart-rate signal (e.g. Fitbit Air with "Share heart rate" on, chest straps, many watches).
- **History and daily recovery data** from the Google Health API (Fitbit/Google wearables), optional.
- **On-demand AI coaching through Claude:** a local, read-only Claude connector (MCP server) so users can ask Claude for weekly reviews and questions about their own data, with no paid AI API.
- **Private by design:** all data stays on the user's Mac. No accounts, no servers, no tracking.

Distribution: **GitHub** (source + free GitHub Releases). Not the Mac App Store.

### Non-goals (v1)
- Not a medical device: no diagnosis, no arrhythmia/AFib detection, no clinical alerts.
- No iOS/Android app, no cloud sync between devices, no social features.
- No nutrition/calorie tracking.
- No writing data back to Google or to any device.

---

## 2. Users & key use cases

**Primary user:** a software professional working at a Mac, training toward a fitness goal date (e.g. a wedding), owning a Fitbit Air or another wearable that broadcasts heart rate.

| # | As a user I want to… | So that… |
|---|---|---|
| U1 | see my live heart rate in the menu bar while working | I notice stress and sedentary spikes |
| U2 | get a gentle nudge when my HR stays high while I'm sitting | I take a breathing/movement break |
| U3 | see a morning readiness view (HRV, resting HR, sleep vs *my* baseline) | I know whether to train hard or easy today |
| U4 | track my progress from day 1 to my goal date | I stay motivated and see real change |
| U5 | log habits in ~10 seconds a day | I learn which habits move my HRV/RHR |
| U6 | ask Claude "give me my weekly review" or "why was my HRV low Tuesday?" | I get coaching without paying for an AI API |
| U7 | export or delete all my data | I stay in control |

---

## 3. Functional requirements

Priority: **P0** = v1 must-have, **P1** = v1 should-have, **P2** = later.

### F1. Onboarding & settings
- **F1.1 (P0)** First-run flow: what the app does; health disclaimer ("not medical advice; consult a doctor before major training changes"); choose data sources: *Live heart rate only*, or *Live + Google Health history*.
- **F1.2 (P0)** Set goal date (label e.g. "Wedding"), optional resting-HR/HRV intentions (free text, no prescribed targets).
- **F1.3 (P0)** Settings: units, work hours, quiet hours, nudge thresholds (F2.6), check-in reminder time, launch at login, data folder location (read-only display), connected sources.
- **F1.4 (P1)** In-app disclosure screen listing every Google Health data type read and why (Google requires this kind of in-app disclosure for health data; keep it accurate).

### F2. Live heart rate (Bluetooth, official standard only)
- **F2.1 (P0)** Scan for devices advertising the **Bluetooth Heart Rate Service (0x180D)**; let the user pick one; remember it and auto-reconnect.
- **F2.2 (P0)** Parse **Heart Rate Measurement (0x2A37)** per the Bluetooth spec: 8/16-bit HR, sensor-contact flags, energy expended, and **RR intervals** (1/1024 s units) when present.
- **F2.3 (P0)** Menu bar shows live BPM (or a heart icon + "—" when disconnected). Popover shows current BPM, a 10-minute sparkline, the HR zone, and connection state.
- **F2.4 (P0)** Record **sessions** (start/stop manually, plus auto "desk session" while connected): timestamps, BPM samples, RR intervals.
- **F2.5 (P1)** If RR intervals exist, compute a short-window **live RMSSD**. Label it clearly as *live HRV*. It is **not comparable** to the sleep HRV from Google; never mix the two in baselines.
- **F2.6 (P0)** **Elevated-at-desk nudge:** if live HR ≥ (resting-HR baseline + *threshold*, default 25 bpm) for ≥ *duration* (default 10 min), outside a manual workout session, inside work hours, and not in quiet hours → one macOS notification suggesting a 2-minute breathing or walk break. Max 1 per hour (configurable). No resting-HR baseline yet → use a user-set fallback.
- **F2.7 (P0)** Zones: % of estimated max HR (default 220 − age) or user-entered max HR; show the "easy/Zone 2" band explicitly.
- **F2.8 (P0)** Robust connection handling: Bluetooth off/unauthorized states, device out of range, reconnect with backoff, no CPU spin. Never send commands to the device beyond standard notify subscription.

### F3. Google Health sync (optional)
- **F3.1 (P0)** **Bring-your-own Google OAuth client** (keeps it free and avoids Google's 100-user cap for shared unverified apps): a guided setup screen with step-by-step instructions + screenshots/links for creating a Google Cloud project, enabling the Google Health API, configuring the consent screen, and creating a **Desktop app** OAuth client. The user pastes the client ID (and secret if Google requires one for desktop clients).
- **F3.2 (P1)** Optional "shared client" mode for small beta groups (≤100 users, unverified-app warning) via a build-time config value. Off by default.
- **F3.3 (P0)** OAuth 2.0 **authorization code + PKCE** with loopback redirect (127.0.0.1, random port) opened in the default browser. Request only the scopes needed (§11 Q1). Tokens stored in the **macOS Keychain** only.
- **F3.4 (P0)** Handle expiring/revoked refresh tokens gracefully: a clear "Reconnect Google" banner, no crash, no data loss (see §11 Q2 for testing-mode token expiry).
- **F3.5 (P0)** Backfill the last **90 days** on first connect, then incremental sync: on launch, on wake, and every 3 hours while running. Idempotent upserts; per-data-type sync cursor.
- **F3.6 (P0)** Data types (exact type names/endpoints per §11 Q1): daily resting HR, daily HRV (RMSSD, sleep-based), sleep (duration, start/end, stages if available), steps, workouts/exercise sessions; P1: SpO2, respiratory rate, VO2 max, heart-rate samples aggregated to 1-minute.
- **F3.7 (P0)** Use Google's **reconcile** endpoint (or equivalent) when multiple sources overlap, to avoid double counting (e.g. phone + tracker steps).
- **F3.8 (P0)** Respect rate limits: exponential backoff with jitter on 429/5xx; log errors locally; surface a human-readable sync status.

### F4. Baselines & morning readiness
- **F4.1 (P0)** Rolling **personal baselines** (30-day median and MAD) for resting HR, sleep HRV, sleep duration. Show "Calibrating (n/14 days)" until ≥14 valid days.
- **F4.2 (P0)** **Readiness (v1 heuristic, tunable, not clinically validated):**
  - robust z-scores: `z = (today − median30) / (1.4826 × MAD30)`, clipped to [−3, 3]
  - `hrv_z` (higher is better), `rhr_z = −z(rhr)` (lower RHR is better), `sleep_z` vs personal sleep baseline
  - `score = clamp(50 + 10 × (0.5·hrv_z + 0.3·rhr_z + 0.2·sleep_z), 0, 100)`
  - bands: **≥60 "Go hard"**, **40–59 "Normal day"**, **<40 "Take it easy"**
  - always show the *why* ("HRV 18% above your baseline, RHR 2 bpm below, sleep 40 min short") with numbers. Keep weights in one config struct.
- **F4.3 (P0)** Morning notification (configurable time) with the readiness band + one-line reason, once today's data has synced.

### F5. Goal progress
- **F5.1 (P0)** Snapshot a **starting baseline** (first 14 calibrated days) and show a countdown to the goal date.
- **F5.2 (P0)** Charts (Swift Charts): resting HR, sleep HRV, sleep duration, steps: daily points + 7-day rolling average, weekly and monthly views, start-baseline reference line.
- **F5.3 (P1)** Monthly progress card: change vs start for each metric, in plain language, with no invented targets.

### F6. Daily check-in (~10 seconds)
- **F6.1 (P0)** Quick form in the popover + reminder notification: alcohol (none/some/a lot), late heavy meal (y/n), caffeine after 3 pm (y/n), workout (none/easy/moderate/hard + type), work location (office/home), late screens (y/n), stress (1–5), free note.
- **F6.2 (P1)** User can add/rename/hide tags.
- **F6.3 (P0)** A check-in is attributed to the **night that follows**, so it's compared with the *next morning's* HRV/RHR.

### F7. Habit insights
- **F7.1 (P1)** For each tag: compare next-morning HRV and RHR (as z-scores vs baseline) with vs without the tag. Show the difference, sample counts, and a confidence label.
- **F7.2 (P1)** Only show an insight when each group has ≥5 samples. Wording must state association, not causation ("On nights after alcohol, your HRV averaged 14% lower (8 vs 21 nights)").

### F8. Claude connector (local MCP server, read-only)
- **F8.1 (P0)** Separate executable `pulsebar-mcp` (stdio transport) shipped inside the app bundle. Opens the database **read-only**. No network access. No write tools.
- **F8.2 (P0)** Tools (all dates ISO-8601, user's local time zone, units in every response):
  - `get_daily_metrics(start_date, end_date)`
  - `get_baselines(as_of_date)`
  - `get_readiness(date)`, which includes the "why" breakdown
  - `get_trends(metric, period: week|month, since_date)`
  - `get_goal_progress()`: start baseline, latest values, days remaining
  - `get_checkins(start_date, end_date)`
  - `get_habit_impact(metric: hrv|resting_hr)`
  - `get_live_sessions(start_date, end_date)`: summaries only (avg/max HR, duration, live RMSSD), no raw samples
- **F8.3 (P0)** Cap response sizes (e.g. ≤ 366 days per call); clear errors for bad input.
- **F8.4 (P0)** "Connect to Claude" screen in Settings: shows the exact config snippet for the Claude desktop app, with a copy button and step-by-step instructions. Do not silently edit other apps' config files; if offering an automatic "Add for me", show the diff and ask first.
- **F8.5 (P1)** Ship a ready-made prompt list in the README ("Give me my weekly review", "Plan this week's training from my recovery", …).

### F9. Data control
- **F9.1 (P0)** Export all data to CSV + JSON.
- **F9.2 (P0)** "Delete all data" (DB + Keychain tokens) with confirmation; "Disconnect Google" revokes the token.
- **F9.3 (P1)** Retention: raw live samples kept 90 days, then reduced to per-session summaries.

### F10. Updates
- **F10.1 (P1)** Check the GitHub Releases API (at most daily, can be disabled) and show "Update available" with a link. No auto-install (avoids needing paid code signing).

---

## 4. Non-functional requirements

- **Privacy:** no telemetry, no analytics, no third-party network calls except Google's OAuth/Health endpoints and the GitHub Releases check (disable-able). Logs never contain tokens or raw health values.
- **Security:** tokens only in Keychain; DB file permissions 0600 in `~/Library/Application Support/PulseBar/`; MCP server read-only; PKCE + state parameter; validate all API responses.
- **Performance:** idle CPU ≈ 0%; live mode < 2% CPU; memory < 150 MB; charts render < 200 ms for 1 year of daily data.
- **Reliability:** works fully offline (live HR + existing data); sync is idempotent and resumable; versioned DB migrations; no data loss on crash.
- **Accessibility:** VoiceOver labels, Dynamic Type where applicable, never color-only status (pair with text/icons), light & dark mode.
- **Battery:** no polling loops; BLE notify only; sync timers coalesced.
- **Quality:** unit tests for parsing (0x2A37 incl. RR), baseline/readiness math, habit stats, sync upserts, and MCP tool outputs; mocks for BLE and the Google API. CI must pass before release.
- **Health-safety wording:** neutral, encouraging, never alarming; no diagnoses; disclaimer in onboarding, About and README.

---

## 5. Architecture

```
┌──────────────────────── PulseBar.app (SwiftUI, menu bar) ────────────────────────┐
│  UI (MenuBarExtra + popover + Settings + Charts)                                  │
│      │                                                                            │
│  Core services                                                                    │
│   ├─ LiveHR (CoreBluetooth, 0x180D/0x2A37) ──► Sessions                           │
│   ├─ GoogleHealthClient (OAuth PKCE, Keychain, sync engine)                       │
│   ├─ Metrics (baselines, readiness, habit stats) - pure Swift, fully unit-tested  │
│   └─ Notifications (nudges, morning card, check-in reminder)                      │
│      │                                                                            │
│  Store (SQLite via GRDB, migrations)  ◄──── read-only ────  pulsebar-mcp (stdio)  │
└───────────────────────────────────────────────────────────────▲──────────────────┘
                                                                 │ MCP (local)
                                                         Claude desktop app
```

- **Language/stack:** Swift 6, SwiftUI, Swift Charts, CoreBluetooth, AuthenticationServices/URLSession, macOS **26+** (raised from 14+ on 2026-11-06: use current SwiftUI/Liquid Glass APIs directly, no availability shims).
- **Packages:** one Swift package `PulseBarCore` (models, store, metrics, Google client, BLE parsing; no UI) used by both the app target and the `pulsebar-mcp` executable target.
- **DB:** SQLite via **GRDB.swift** (MIT). Not SwiftData, because the MCP server needs a stable, documented schema.
- **MCP:** the official MCP Swift SDK if it fits (verify, §11 Q5); otherwise a minimal, well-tested JSON-RPC-over-stdio implementation of the MCP tools subset.
- **Not sandboxed** (not on the App Store); still request only needed permissions: `NSBluetoothAlwaysUsageDescription`, notifications.

### 5.1 Data model (initial)

| Table | Key columns |
|---|---|
| `daily_metrics` | `date` (PK, local), `resting_hr`, `hrv_rmssd_ms`, `sleep_minutes`, `sleep_start`, `sleep_end`, `deep_min`, `rem_min`, `light_min`, `awake_min`, `steps`, `spo2_avg`, `resp_rate`, `vo2max`, `source`, `updated_at` |
| `workouts` | `id`, `start`, `end`, `type`, `avg_hr`, `max_hr`, `source` |
| `hr_minutes` | `minute_ts` (PK), `bpm_avg`, `bpm_min`, `bpm_max`, `source` (P1, from Google) |
| `live_sessions` | `id`, `start`, `end`, `kind` (desk/workout), `device_name`, `avg_hr`, `max_hr`, `live_rmssd_ms` |
| `live_samples` | `session_id`, `ts`, `bpm`, `rr_ms` (nullable) |
| `checkins` | `night_of` (date), `tag`, `value`, `created_at` |
| `goal` | `label`, `goal_date`, `start_snapshot_json` |
| `sync_state` | `data_type` (PK), `last_success`, `cursor`, `last_error` |
| `settings` | key/value |

---

## 6. UX outline

- **Menu bar:** heart icon + live BPM (colored by zone, text always present).
- **Popover tabs:** *Now* (live HR, sparkline, zone, session button) · *Today* (readiness band + why, last night's sleep, RHR, HRV) · *Progress* (charts, countdown) · *Check-in* (quick form).
- **Settings window:** Sources (Bluetooth device, Google), Goal, Nudges, Notifications, Claude connector, Data (export/delete), About (disclaimer, licenses).
- Tone: calm, encouraging, numbers first, no streak-shaming.

---

## 7. Repository layout

```
pulsebar/
├─ SPEC.md                 (this file)
├─ README.md               (what, screenshots, install, Gatekeeper steps, Google setup, Claude setup, privacy)
├─ LICENSE                 (MIT)
├─ PulseBar.xcodeproj  or  Project.swift / Package.swift
├─ App/                    (SwiftUI app target)
├─ Packages/PulseBarCore/  (Sources/, Tests/)
├─ MCP/                    (pulsebar-mcp executable target)
├─ docs/                   (google-setup.md, claude-connector.md, privacy.md, architecture.md)
└─ .github/workflows/      (ci.yml, release.yml)
```

---

## 8. Free distribution via GitHub

- **CI (GitHub Actions, free for public repos):** on every PR, build + run all tests on a macOS runner.
- **Release:** on tag `v*`, build the app, **ad-hoc sign** it (no paid Apple account), zip it, attach to a GitHub Release with SHA-256 checksums and release notes.
- **README install steps** must explain the unsigned-app flow on current macOS: download → unzip → move to Applications → open → when macOS blocks it, go to **System Settings → Privacy & Security → "Open Anyway"** (verify the exact current wording/steps, §11 Q6). Also document **build from source** with Xcode as the trust-maximizing option.
- Known limitation to document: with ad-hoc signing, macOS may re-ask for Bluetooth/Keychain permission after updates.

---

## 9. Milestones & acceptance criteria

| # | Milestone | Done when |
|---|---|---|
| **M0** | Scaffold: repo, targets, `PulseBarCore`, GRDB, CI building + a passing test, MIT license, README skeleton | `xcodebuild test` passes locally and in CI |
| **M1** | Live HR: scan, pick, connect, parse 0x2A37 (incl. RR), menu-bar BPM, sparkline, zones, reconnect | Live BPM from my Fitbit Air (Share heart rate on) or any HR strap updates ≤2 s latency; parser unit tests cover all flag combos |
| **M2** | Storage + sessions + desk nudge + notifications | Sessions persist across restarts; nudge fires once under simulated sustained high HR, respects work/quiet hours and rate limit |
| **M3** | Google Health: BYO-client setup screen, PKCE login, Keychain, 90-day backfill, incremental sync, reconcile, error/re-auth UX | My last 90 days of RHR/HRV/sleep/steps appear correctly vs the Google Health app; re-running sync creates no duplicates; revoking access shows "Reconnect" |
| **M4** | Baselines, readiness, morning notification, goal countdown, charts | Readiness math unit-tested with fixtures; "Calibrating" state below 14 days; charts show 7-day averages and the start line |
| **M5** | Daily check-in + habit insights | Check-in in ≤10 s; insights hidden below 5 samples per group; wording is association-only |
| **M6** | `pulsebar-mcp` read-only connector + "Connect to Claude" screen | Claude desktop app lists the tools; "give me my weekly review" works end-to-end; server cannot write (tested) |
| **M7** | Polish & v1.0 release: export/delete, retention, update check, accessibility pass, docs, release workflow | Fresh Mac can install from a GitHub Release following only the README |

---

## 10. Testing plan

- **Unit:** BLE parsing; robust z-scores, baselines, readiness bands; check-in → night attribution; habit stats thresholds; DB migrations; sync upsert idempotency; MCP tool schemas and outputs (golden files).
- **Integration:** Google client against recorded fixtures (no real tokens in repo); BLE with a mock peripheral protocol.
- **Manual:** real Fitbit Air + Mac; Bluetooth off/on; sleep/wake; network loss mid-sync; token revoked; first run with zero data.

---

## 11. Open questions: verify before building on them

1. **Google Health API specifics:** exact base URL/version (v4 vs v4beta), data-type names, endpoints (`list`, `reconcile`, rollups), pagination, and the **minimal OAuth scopes** for the data in F3.6. Source: https://developers.google.com/health
2. **OAuth token lifetime for unverified/testing-mode projects with Google Health's restricted scopes:** do refresh tokens expire after ~7 days? Can a personal BYO project be set to "In production" without verification? Design F3.4 for the worst case either way.
3. **Does the Fitbit Air's heart-rate broadcast include RR intervals?** If not, hide live HRV (F2.5) for that device.
4. **Can the Mac connect to the Air's HR broadcast while the phone's Google Health app is also connected?** Test real-world behavior; document it.
5. **MCP Swift SDK:** does the official SDK support stdio servers on macOS 14 with current MCP spec? Otherwise implement the minimal subset.
6. **Current macOS steps for opening an ad-hoc-signed app downloaded from GitHub** (wording and location of "Open Anyway").
7. **Google API terms for open-source desktop apps:** confirm BYO-client is permitted and what the in-app disclosure must contain.

---

## 12. Definition of done (v1.0)

- All P0 requirements met; M0–M7 acceptance criteria pass.
- No paid services anywhere in the build, release, or runtime path.
- No private/undocumented device protocols; nothing ever written to the wearable.
- README lets a stranger install, connect a heart-rate device, optionally connect Google, and connect Claude, unaided.
- Disclaimer present in onboarding, About, and README.
