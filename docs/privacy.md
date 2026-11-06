# Privacy

PulseBar has no accounts, no servers and no analytics. Your data stays on your Mac.

## What is stored, and where

| Data | Where | Protection |
|---|---|---|
| Live heart-rate sessions, samples, check-ins, goal, settings, synced Google data | `~/Library/Application Support/PulseBar/pulsebar.sqlite` | Folder `0700`, file `0600` (your user only). Use FileVault for disk encryption. |
| Google refresh token and client secret | macOS Keychain (service `io.github.pulsebar`), this device only | Encrypted by macOS, never synced to iCloud |

Raw live heart-rate samples older than 90 days are automatically reduced to per-session summaries.

## Network use (complete list)

1. **Google sign-in and Google Health API** (`accounts.google.com`, `oauth2.googleapis.com`,
   `health.googleapis.com`): only if you connect Google, read-only, using *your own* OAuth client.
2. **GitHub Releases check** (`api.github.com`): at most once a day, no identifiers sent, can be turned off
   in Settings → About. PulseBar never downloads or installs anything itself.

Logs never contain tokens or health values.

## Google Health data

PulseBar reads only: daily resting heart rate, daily sleep HRV, sleep sessions and stages, steps, exercise
sessions, nightly SpO2 average, breathing rate and VO2 max. It uses them only to show them to you in the app.
It never writes to Google Health. PulseBar's use of Google Health data complies with the Google Health API
Developer and User Data Policy, including its Limited Use requirements. The in-app disclosure in
Settings → Google is shown before you consent.

## Claude

If, and only if, you turn on Settings → Claude and add the connector to Claude desktop, Claude can read your
PulseBar data when you ask it something. What Claude reads becomes part of that conversation and is handled
under your Claude account's terms. The connector opens the database read-only, can't change anything, and
makes no network calls itself. Turn it off any time.

## Your controls

- **Export:** Settings → Data → Export all data (CSV per table + `pulsebar.json`). Tokens are never exported.
- **Delete:** Settings → Data → Delete all data. Wipes the database, revokes Google access and removes
  PulseBar's Keychain items.
- **Disconnect Google:** Settings → Google → Disconnect (revokes the token at Google).
