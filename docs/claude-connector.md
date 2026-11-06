# Claude connector (`pulsebar-mcp`)

PulseBar includes a small **read-only** [Model Context Protocol](https://modelcontextprotocol.io) server so you
can ask Claude about your own data, with no paid AI API involved.

## Set up

1. PulseBar → **Settings → Claude** → turn on **Allow Claude to read my PulseBar data**.
2. Click **Test connector**. It should say *Working: 8 read-only tools ready*.
3. In Claude desktop: **Claude menu → Settings… → Developer → Edit Config**, and add (or merge):

   ```json
   {
     "mcpServers": {
       "pulsebar": {
         "command": "/Applications/PulseBar.app/Contents/MacOS/pulsebar-mcp"
       }
     }
   }
   ```

   (Settings → Claude shows the exact path for your copy, with a Copy button.)
4. Quit Claude completely and reopen it. *pulsebar* appears under **Connectors**.

## Things to ask

- "Give me my weekly review."
- "Plan this week's training from my recovery."
- "Why was my HRV low on Tuesday?"
- "How am I progressing toward my goal?"
- "Which of my habits line up with better sleep HRV?"

## Tools

| Tool | What it returns |
|---|---|
| `get_daily_metrics(start_date, end_date)` | Daily resting HR, sleep HRV, sleep and stages, steps, SpO2, breathing rate, VO2 max |
| `get_baselines(as_of_date)` | 30-day medians/MADs and calibration status |
| `get_readiness(date)` | Score, band and the "why" |
| `get_trends(metric, period, since_date)` | Weekly / monthly means |
| `get_goal_progress()` | Goal, days remaining, starting baseline, recent values |
| `get_checkins(start_date, end_date)` | Evening check-ins |
| `get_habit_impact(metric)` | Habit associations (≥5 nights per group) |
| `get_live_sessions(start_date, end_date)` | Session summaries only, no raw samples |

Dates are `YYYY-MM-DD` in your local time zone, ranges are capped at 366 days, and every response states units.

## Safety and privacy

- The server opens the database **read-only**; SQLite itself rejects writes (covered by tests).
- It makes no network calls. It only answers Claude over standard input/output on your Mac.
- What Claude reads becomes part of that Claude conversation. Turn access off any time in Settings → Claude.
- Protocol: supports MCP 2026-07-28 (per-request metadata, `server/discover`) and earlier versions
  (2024-11-05 – 2025-11-25, `initialize` handshake).

## Troubleshooting

- Claude's MCP logs: `~/Library/Logs/Claude/mcp*.log`.
- Run the server by hand: `/Applications/PulseBar.app/Contents/MacOS/pulsebar-mcp`, then paste
  `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}`.
