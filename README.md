# AgentNotch

A Dynamic Island for the Mac notch that shows what **Claude Code**, **Codex**, and
**OpenCode** are doing while you work on something else.

Native (SwiftUI + AppKit), no dependencies, no server, no network: it only reads
the files the three agents already write to disk.

## Design rationale — The UX DeCode

This app exists for one specific case: you're running more than one agentic
coding tool at once, and you're doing something else entirely — writing,
reading, in a meeting — while they work. The choices below aren't aesthetic
preferences; each is a constraint pulled from *The UX DeCode*, the 13-principle
HCI framework this project was designed against.

| Principle | Decision | Why |
|---|---|---|
| **P4 — Match with mental models** | Borrows iOS 26's Dynamic Island metaphor instead of inventing a new one | The user already carries this mental model from their phone. Reusing it on a genuinely new surface (background agents, not notifications) costs zero learning time |
| **P9 — Cognitive limits** | At rest: nothing. Full detail (session, branch, running tool, tokens, todos) only on hover | Progressive disclosure — nothing sits in the user's working memory that isn't needed for the task in front of them right now |
| **P1 — Accessibility** | Meaning lives in the glyph (terminal, pencil, raised hand…), never in color alone | Color tells you *which* agent; the icon tells you *what's happening* — the interface still reads correctly for anyone who can't rely on hue |
| **P8 — Visibility of system status & feedback** | An agent that needs you turns amber (or red on failure) and breathes for 20 seconds, then holds still | A signal that never stops moving becomes wallpaper — you stop seeing it, and it keeps the display link (and battery) awake for as long as you ignore it. Settling after 20s keeps the signal meaningful without demanding it stay loud forever |
| **P5 — Effective, clear design** | One dominant state at rest: none. No decorative element competes with the one thing that matters when something does need attention | Visual restraint isn't decoration — it's what keeps the notch legible in a single glance instead of one more thing to parse |
| **P3 — Consistency with platform conventions** | Click brings the agent's app forward; ⌥-click opens the project folder in Finder | Standard macOS modifier conventions — no gesture invented that the user has to learn just for this app |

## What it shows

**At rest** — nothing. The notch stays a notch.

**Two ways to signal, chosen from the menu.**

*Line around the notch* — a thin line traces the notch's outline without taking
up space. With more than one agent active it splits into **arcs, one per
agent**, each in its own color: orange for Claude Code, teal for Codex, indigo
for OpenCode. One glance tells you not just that something's running, but
which one.

*Compact island* — the notch widens slightly: a colored dot per agent on the
left, the glyph for what's happening on the right (terminal for a running
command, a raised hand if it's waiting on you, a triangle if it failed). It
takes a bit more menu bar space but reads without leaning in.

In both modes, when an agent needs you its color turns amber (or red on
failure) and starts to **breathe** for 20 seconds, then settles: a perpetual
pulse becomes wallpaper and you stop seeing it, and it would keep the display
link awake for as long as you ignore it.

The notch's bounding box is exact (the calculation from public APIs matches
AppKit's private `_notchFrame` to the point) and the app follows resolution
changes, but **corner radius isn't exposed by any API**: it's eyeballed and
tunable live, without recompiling.

```bash
defaults write local.agentnotch notchCornerRadius -float 8
```

```bash
defaults write local.agentnotch notchLineWidth -float 3
```

**Alert** — when an agent moves from *working* to *waiting on you*, the island
opens for a few seconds with icon, agent name, status, and project, then
returns to the resting indicator. This is the Dynamic Island's compact
transition.

**On hover over the notch** — the island opens fully: up to 4 sessions with
activity icon, title, project, branch, running tool, duration, tokens, and
todos.

### The icons

Meaning lives in the glyph, not the text — a glance has to be enough (P1, P9).

| icon | while working | | icon | when it stops |
|---|---|---|---|---|
| terminal | shell command | | raised hand | waiting on you |
| document | reading | | triangle | error |
| pencil | writing a file | | pause | paused |
| magnifying glass | searching | | checkmark | done |
| globe | web | | | |
| two people | subagent | | | |
| card | MCP tool | | | |
| sparkles | reasoning | | | |

### The style

Continuous corners (squircle) instead of circular arcs, spring morphing, a
real blurred backdrop (`NSVisualEffectView`), a specular edge that fades from
the top, and a background that's **solid black where it touches the notch** —
so it reads as a continuation of the hardware — and turns to glass as it
extends onto the desktop.

Click a row → brings the agent's app to the foreground.
⌥-click → opens the project folder in Finder.

## Where the data comes from

| Agent | Source | How |
|---|---|---|
| Claude Code | `~/.claude/sessions/<pid>.json` + `~/.claude/projects/**/*.jsonl` | the per-PID file gives live processes, the transcript is read in append mode (only new lines each poll) |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` + `session_index.jsonl` | `task_started` / `token_count` / `item_completed`; includes the plan's **rate-limit percentage** |
| OpenCode | `~/.local/share/opencode/opencode.db` (SQLite) | `session`, `message`, `part`, `todo` tables, read-only (`PRAGMA query_only`) |

Everything local, read-only, one polling pass per second.

### How status is inferred

- **working** — a tool is open, or a turn has started and hasn't closed yet, with recent activity
- **waiting on you** — Claude closed with `end_turn`, Codex emitted the turn completion, OpenCode has an assistant message with `time.completed`
- **waiting for confirmation?** — heuristic: a Claude Code tool open for more than 35 seconds with no response is almost always a permission prompt waiting on screen. This is an inference, not a fact: Claude Code doesn't write to the transcript when it shows the prompt.
- **error** — Codex/OpenCode report the turn failing

## Usage

```bash
./build.sh && open AgentNotch.app
```

The app lives only in the menu bar (no Dock icon). From its menu: alert sound,
notch alert, also show idle sessions, launch at login, quit.

To see what the parsers read without opening the panel:

```bash
./.build/release/AgentNotch --dump
```

`--diag` prints the detected notch geometry instead, and
`AGENTNOTCH_FORCE_MODE=alert|expanded|glow|compact` locks the panel in one
state so you can look at it calmly instead of waiting for it to happen, and
`AGENTNOTCH_DEBUG=1` prints mode, notch geometry, and computed rectangles to
stderr every second — useful when what you see doesn't match what the app
thinks it's drawing. On a Mac without a notch (or on an external monitor) the
panel becomes a floating pill centered at the top, with the same shape.

To widen the freshness window during testing — by default a session
disappears after 20 minutes of silence:

```bash
AGENTNOTCH_WINDOW_MIN=1440 ./.build/release/AgentNotch --dump
```

## Icons

`build.sh` looks for two images in the project folder and uses them in
different places:

| file | where it ends up |
|---|---|
| `Icon` / `Icon.png` | bundle icon (`.icns`, every size from 16 to 1024) |
| `outline` / `outline.png` | menu bar icon, as a template image |

The menu bar image has to be a **template image**: black plus an alpha
channel, so macOS recolors it itself — white on a dark bar, black on a light
one, inverted when the menu is open. But an outline drawing often comes from
an export with a "checkerboard" background **painted into the pixels** and no
alpha channel: used as-is, the menu bar would show a checkerboard rectangle.

That's why `tools/make-status-icon.swift` normalizes whatever source it's
given: if alpha exists it respects it, if it's missing it derives it from
luminance (lighter than 90% is background, the rest keeps the antialiased
edges). Then it thickens the stroke a little before downscaling, because at
19pt a thin line falls under a pixel and reads as gray instead of solid. The
factor is the last argument: 0.18 by default, 0 to disable it, higher for a
very thin line drawing.

The converter is compiled once and cached in `.build/`, and the icon only
regenerates when the source image changes — interpreted with `swift
file.swift` the same job takes 25 seconds instead of one.

If the outline is missing the app falls back to a downscaled color icon, and
if that's missing too, to a system symbol: the bare binary launched during
development doesn't even have a `Resources` folder.

The color icon has a transparent background: in Finder it'll show up as a
floating logo, not macOS's standard rounded square. That's a design choice,
not a bug.

## Structure

```
Sources/AgentNotch/
  Models.swift            shared types, formatting
  Config.swift            thresholds and preferences
  Tailer.swift            incremental JSONL reader + tolerant JSON access
  SQLiteLite.swift        minimal read-only SQLite reader
  ClaudeProvider.swift    ┐
  CodexProvider.swift     ├ one parser per agent → [AgentSession]
  OpenCodeProvider.swift  │
  NativProvider.swift     ┘
  SessionStore.swift      polling, urgency ordering, alerts
  NotchShape.swift        continuous-corner silhouette, glass, colors
  NotchView.swift         SwiftUI: line / compact island / alert / expanded
  NotchController.swift   NSPanel, hover, click-through
  LoginItem.swift         launch at login via LaunchAgent
  main.swift              delegate, menu, --dump / --diag
tools/
  make-status-icon.swift  outline-on-light-background to template image
```

## Adding a fourth agent

Write a type with `func poll() -> [AgentSession]`, add the case to
`AgentKind` (tag, color, bundle id), and fold it into the sum inside
`SessionStore.tick()`. The rest — ordering, alerts, UI — works on its own.

## Known limits

- The parsers depend on the three agents' on-disk formats: an update that
  changes the layout can make a field disappear. `--dump` is the fast way to
  notice.
- **The context bar only shows where the window is declared by the agent**,
  which today means Codex only (`model_context_window`). Claude Code and
  OpenCode don't write it anywhere: assuming it produced false alarms — a
  real Claude session sat at 226k against an assumed 200k ceiling, so a red
  bar on a perfectly healthy session. For the others, just the token count is
  shown. If you know a model's real limit, add it to `Config.knownWindows`
  and the bar comes back.
- Cost is only real for OpenCode, which saves it in the database; Claude Code
  and Codex don't write it to their session files.
- The app is ad-hoc signed: it runs on your machine, it isn't distributable
  as-is.

## A note on performance

The app stays under 1% CPU and ~24 MB, but it took three attempts to get
there, and it's worth writing down so the next person who touches this line
doesn't redo them. This isn't a side note — it's the same P5 argument as the
visual restraint above: performance *is* usability here, because the whole
premise is an app you're not supposed to notice.

- **Blur costs forever.** `.blur()` is a Core Animation filter reapplied on
  every recomposition. Nine blurred paths held ~2% CPU permanently.
- **`.drawingGroup()` was worse**: an offscreen buffer per arc, memory from
  24 to 107 MB.
- **`withAnimation(.repeatForever)` doesn't cancel** by reassigning the
  property it animates. The only reliable way to stop it is to destroy the
  view hosting it — that's why the breathing line is a separate view type,
  not a flag. Leaving it running kept the display link awake for as long as
  a session stayed in the waiting state.

If a change drives CPU up, `sample <pid>` tells you which thread is consuming
it in a few seconds.
