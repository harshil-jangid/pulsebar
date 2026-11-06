# PulseBar

A free, open-source macOS menu-bar app that helps desk workers improve cardiovascular
fitness and recovery (HRV up, resting heart rate down) toward a personal goal date,
using their own wearable data. All data stays on your Mac.

> **Status:** early development (milestone M0: scaffold). Nothing user-facing yet.

> **Health disclaimer:** PulseBar is not a medical device and does not give medical
> advice. It does not diagnose anything. Consult a doctor before making major
> changes to your training.

## Features (planned)

- Live heart rate in the menu bar from any device broadcasting the standard
  Bluetooth Heart Rate Service
- Optional history and recovery data from the Google Health API
- Morning readiness vs. your own baseline, goal progress, daily check-ins
- A local, read-only Claude connector (MCP) for weekly reviews
- No accounts, no servers, no tracking

## Install

_TODO (M7): download from GitHub Releases, plus the steps for opening an
ad-hoc-signed app on current macOS._

## Build from source

Requirements: macOS 26+, Xcode 26+ (free from the Mac App Store), Homebrew.

```bash
brew install xcodegen
xcodegen generate          # creates PulseBar.xcodeproj from project.yml
open PulseBar.xcodeproj    # then Run the "PulseBar" scheme
```

Run the tests from the command line:

```bash
xcodebuild test -project PulseBar.xcodeproj -scheme PulseBar -destination 'platform=macOS'
```

Core-library tests only (works even with just the Command Line Tools):

```bash
./scripts/test-core.sh
```

## Repository layout

| Path | What |
|---|---|
| `App/` | SwiftUI menu-bar app |
| `Packages/PulseBarCore/` | Models, storage (GRDB/SQLite), metrics, BLE parsing, Google client. No UI. |
| `MCP/` | `pulsebar-mcp`, the read-only Claude connector |
| `project.yml` | XcodeGen spec; the `.xcodeproj` is generated, not committed |
| `SPEC.md` | Product & build spec |

## Connect Google Health / Claude

_TODO (M3 / M6)._

## Privacy

No telemetry or analytics. The only network calls will be to Google's OAuth/Health
endpoints (if you connect Google) and an optional GitHub Releases update check.

## License

[MIT](LICENSE)
