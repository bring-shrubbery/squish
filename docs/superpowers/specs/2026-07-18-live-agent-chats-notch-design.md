# Live Agent Chats in the Notch — Design

**Date:** 2026-07-18
**Status:** Implemented, then revised after first-run testing

## Revision (post-testing)

First-run testing surfaced four corrections that supersede parts of the original
design below:

1. **Hook event:** use Claude Code's **`PermissionRequest`** hook, not
   `PreToolUse`. `PreToolUse` fires on *every* tool call and forced a notch prompt
   even in accept-edits/bypass/auto modes; `PermissionRequest` fires only when a
   permission dialog would genuinely appear. Output shape is
   `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny"}}}`.
2. **Free-text answers are out of scope:** Claude's built-in `AskUserQuestion`
   does not surface to hooks, so arbitrary typed answers can't be intercepted. The
   notch is **permission approve/deny** focused. The keystroke write-path remains
   in the code but dormant, and Accessibility is requested lazily (never on
   enable), so enabling the feature triggers **no OS permission prompts**.
3. **Appearance:** force DynamicNotchKit's `.notch` style + a dark color scheme so
   the popup always renders as a black Dynamic Island (the `.floating` fallback
   looked like a light notification and hid the compact state on non-notch
   displays).
4. **Live-activity:** the horizontal compact state now reliably shows (no longer
   buried under constant prompts) with a pulsing "coding active" animation.

The sections below are the original design and are kept for context.

## Summary

Add a toggle-able feature that surfaces **live AI agent chats** in the macOS
notch. When agents are active, the notch expands **horizontally** into a compact
pill. Clicking it opens a **detailed dropdown** listing the active sessions. When
a Claude Code agent needs a decision (a tool-permission prompt) or asks a
question, the notch **opens vertically** and lets the user **approve/deny** or
**type an answer** directly. Multiple concurrent requests are shown as **mini
tabs**; a tab closes once its request is resolved, and the notch collapses back
to horizontal (or hides) when nothing is pending.

The whole feature is gated behind a **"Live chats"** toggle and is fully
reversible.

## Decisions (locked during brainstorming)

1. **Answer channel:** Claude Code **hooks**. A blocking `PreToolUse` hook is the
   rendezvous point for permission decisions. This is Claude Code-specific.
2. **Provider scope:** Claude Code is **interactive** (answerable in-notch).
   Codex and Gemini appear as **display-only** active chats and deep-link to the
   terminal.
3. **Interaction types:** **permissions** (allow / deny / always-allow) *and*
   **full free-text answers**. Permissions resolve purely through the hook.
   Free-text answers require a **keystroke write-path** into the session's
   terminal (macOS Accessibility / CGEvent), because a hook cannot type an
   arbitrary reply into a live interactive session.
4. **Scope:** everything in one spec/implementation, structured so the keystroke
   write-path is a cleanly separable layer.
5. **Setup:** **auto-install with consent** — on enabling the feature, Squish
   shows what it will do, then merges its hook into the global
   `~/.claude/settings.json` and prompts the macOS Accessibility grant. Fully
   reversible via a disable button.

## Non-goals

- Interactive answering for Codex / Gemini (display-only for now).
- Driving agents Squish did not observe (we do not spawn agents; we observe and
  respond to existing sessions).
- Replacing the existing Compact-alerts notch feature. This is additive and
  reuses the same notch library.

## Architecture

Two independent data sources feed one notch UI.

### A. Active-chat display (passive, all providers)

Reuses the existing `SessionScanner`. A session is considered **active** when its
log was updated within a short window (default 90s) **or** it currently has a
pending request. Grouping: `working` (streaming / very recently updated),
`waiting` (has a pending request), `idle` (active window but no recent write).
Scoped to the monitored folder, consistent with the rest of the app.

### B. Interactive requests (live, Claude Code only)

A **file-based rendezvous** between Claude Code's hook process and Squish, under
`~/.squish/live/`:

```
Claude wants a tool  →  Squish hook executable fires (inside Claude's process)
   1. Reads hook JSON on stdin (tool name, tool input, cwd, session id).
   2. Heartbeat gate: if ~/.squish/live/heartbeat is stale, the feature is off,
      or cwd is outside the monitored folder → exit 0 with no decision
      (Claude falls back to its own prompt). NEVER blocks in this case.
   3. Otherwise writes  requests/<id>.json  with:
      { id, sessionId, cwd, kind, toolName, inputSummary, options?, tty, pid, ppid, createdAt }
   4. BLOCKS, polling for  requests/<id>.decision.json  (with ~5 min timeout).
Squish (FSEventMonitor on requests/)
   5. Reads the request → shows notch tab → user decides.
   6. Writes  requests/<id>.decision.json  = { allow | deny | alwaysAllow | answer:"…" }.
Hook:
   7. Unblocks, emits the matching hook-response JSON to Claude, deletes the
      request + decision files, exits.
```

**Critical safety rule — passthrough when Squish is not listening.** The hook is
a **no-op** unless Squish is actively present. Squish refreshes
`~/.squish/live/heartbeat` (mtime + pid + monitored-root) on a timer while the
feature is enabled. If the heartbeat is stale (older than e.g. 3× the refresh
interval), the feature disabled, or the session's cwd is outside the monitored
root, the hook returns immediately with no opinion. This guarantees that
installing the hook can never hang a Claude session when Squish is closed. Even
when Squish is present, the hook has a generous timeout after which it falls back
to Claude's native prompt.

**Two response paths once the user decides:**

- **Permission (allow / deny / always-allow):** handled entirely through the
  hook's return value (`PreToolUse` `permissionDecision`). No Accessibility
  needed. Rock-solid.
- **Free-text answer:** the decision file carries `answer:"…"`. Squish injects it
  into the session's terminal via the **keystroke write-path**, locating the
  window from the `tty`/`pid` the hook reported. If Accessibility is unavailable,
  it degrades to "answer copied to clipboard + user notification." (For a `question`
  kind that arrives via a tool prompt, the hook also returns the answer as feedback
  text so Claude has the response inline; the keystroke path covers native
  free-text prompts.)

## Components

### SquishCore (pure, unit-testable — matches existing test style)

- **`LiveAgentModels.swift`** — wire format shared with the hook executable:
  - `RequestKind` = `.permission` | `.question`
  - `PendingRequest` { id, sessionId, cwd, kind, toolName, inputSummary, options: [String]?, tty, pid, ppid, createdAt }
  - `AgentDecision` = `.allow` | `.deny` | `.alwaysAllow` | `.answer(String)`
  - Codable encoders/decoders for both, plus the Claude hook-response JSON shape
    (`{"hookSpecificOutput": {"hookEventName":"PreToolUse","permissionDecision":…}}`).
- **`RequestSpool.swift`** — the rendezvous protocol: directory layout, atomic
  request write, decision read/write, request enumeration, stale-file cleanup,
  timeout constants, heartbeat read/write helpers. Pure filesystem logic testable
  against a temp directory.
- **`HookSettings.swift`** — merge/unmerge Squish's hook block into a decoded
  `settings.json` dictionary **without clobbering** the user's existing hooks;
  produces the exact JSON to write and can detect whether it is already
  installed. Pure and unit-testable.
- **`LiveActivity.swift`** — the "is this session active?" predicate and the
  `working` / `waiting` / `idle` grouping used by the UI. Pure function over
  `[CodingSession]` + `[PendingRequest]` + `now`.

### SquishApp (integration, @MainActor)

- **`AgentControlCenter.swift`** — the brain of path B. Owns a `FileSystemEventMonitor`
  on the spool `requests/` dir, refreshes the heartbeat on a timer, cleans stale
  files on launch, publishes `@Published pendingRequests: [PendingRequest]`, and
  exposes `resolve(_ request, with decision)` which writes the decision file and
  (for `.answer`) invokes `TerminalResponder`. Starts/stops with the toggle.
- **`HookInstaller.swift`** — installs/removes the hook in
  `~/.claude/settings.json` (backup before write, restore on removal, uses
  `HookSettings`), points the hook command at the bundled executable, and
  requests Accessibility (`AXIsProcessTrustedWithOptions`). Surfaces install +
  Accessibility status.
- **`TerminalResponder.swift`** — the keystroke write-path. Given `pid`/`ppid`/`tty`,
  resolves the owning terminal app + window via Accessibility, focuses it, sets
  the answer text (paste), and sends Return. Clipboard + `NSUserNotification`
  fallback when Accessibility is denied or the window can't be found. Isolated so
  its fragility is contained and swappable.
- **`LiveChatsNotchController.swift`** — the notch presenter (sibling of the
  existing `NotchAlertController`). Drives DynamicNotchKit between the three
  states below based on `AgentControlCenter` + active-session state. Handles the
  click-to-expand callback and outside-click collapse. Coexists with
  `NotchAlertController` (compact alerts still work).
- **Notch SwiftUI views:**
  - `LiveChatsCompactView` — horizontal pill (compactLeading/compactTrailing):
    provider dots + count + working shimmer.
  - `LiveChatsPanelView` — expanded detailed list: per-session row (glyph, title,
    project, context-% bar, status chip; inline Approve/Deny for waiting Claude
    rows; "Open in terminal" for other providers).
  - `RequestPromptView` — the vertical-open prompt: tab strip (when >1 pending) +
    body (permission buttons or question text/options + text field + Send).

### The hook itself

- A **bundled Swift executable** (`squish-hook`) shipped inside the app bundle
  (added as a new `executableTarget` in `Package.swift`, and copied into
  `Support/` resources for the packaged app). It reads hook JSON on stdin, runs
  the heartbeat gate + spool rendezvous, and emits Claude's hook-response JSON.
  It imports **SquishCore** so the wire format is literally the same code as the
  app — no bash quoting fragility. Testable via fixture stdin + a pre-seeded
  decision file.

### AppState / app wiring

- New `AppSection.liveChats` with title "Live chats" and an SF Symbol, plus a
  view alongside Costs / Compact alerts showing: the on/off toggle
  (`liveChatsEnabled`, persisted like `alertsEnabled`), hook-install status,
  Accessibility status, and a **preview** button.
- `AppState` owns the `AgentControlCenter`, starts/stops it with the toggle and
  the monitored folder, feeds it the current `sessions`, and forwards pending
  requests + active sessions to `LiveChatsNotchController`.

## Notch UX (clean, compact, Apple-style)

Three states driven by `LiveChatsNotchController`:

1. **Horizontal (idle-active).** ≥1 active chat, nothing pending. Notch grows
   horizontally only (DynamicNotchKit `.compact`): provider dots
   (Claude pink / Codex cyan / Gemini blue) + a count ("3 active"), with a faint
   animated shimmer on any streaming session. Click → state 2.
2. **Expanded panel (click).** DynamicNotchKit `.expand`. Compact rounded panel:
   scrollable session list, each row = provider glyph, 1-line title, project
   name, thin context-% bar, status chip (`Working…` / `Waiting` / `Idle`).
   Waiting Claude rows expose inline Approve/Deny; other providers show
   "Open in terminal." Outside-click / chevron collapses to horizontal.
3. **Vertical-open (needs you).** A pending request auto-opens the panel
   (`.expand`) even from collapsed. Tab strip across the top (one mini-tab per
   pending request; shown only when >1). Body for the selected request:
   - *Permission:* tool name + readable summary (e.g. `Bash: rm -rf build/`) +
     **Deny** / **Allow once** / **Always allow**.
   - *Question:* question text (+ options as tappable chips) + single-line text
     field + **Send**.
   Resolving a request closes its tab; when the last closes, the notch falls back
   to horizontal (if chats still active) or hides.

Motion & feel: spring transitions, translucent material, SF Symbols, monospaced
digits for %, matching the existing alert view's vocabulary.

## Error handling

- **Passthrough when Squish absent / feature off / out-of-scope cwd:** hook exits
  0 immediately (see safety rule). This is the single most important correctness
  property.
- **Hook timeout (~5 min):** hook returns no decision → Claude uses its native
  prompt. Squish also drops the pending request from the UI when its file
  disappears or ages out.
- **Stale spool files:** cleaned on Squish launch and when the feature toggles on;
  each resolved request's files are deleted by the hook (and defensively by
  Squish).
- **Accessibility denied / window not found:** free-text answers fall back to
  clipboard + notification; permissions are unaffected (they never use
  Accessibility).
- **`settings.json` safety:** merge-with-backup; never clobbers existing hooks;
  disable restores/removes only Squish's block. Malformed existing settings →
  surface an error and do not write.
- **Multiple monitors / no-notch displays:** reuse the existing screen-selection
  logic from `NotchAlertController` (prefer the screen with a notch/safe-area).

## Testing

**SquishCore unit tests (pure, following existing `Tests/SquishCoreTests` style):**

- `RequestSpoolTests` — round-trip request write/read, decision write/read,
  enumeration, stale cleanup, timeout boundary logic, heartbeat freshness.
- `LiveAgentModelsTests` — encode/decode of `PendingRequest` / `AgentDecision`
  and the Claude hook-response JSON shape (golden strings).
- `HookSettingsTests` — install into empty settings, install alongside existing
  unrelated hooks (no clobber), idempotent re-install, uninstall restores prior
  state, malformed-input handling.
- `LiveActivityTests` — active predicate boundaries (90s window), and
  working/waiting/idle grouping across combinations of sessions + pending
  requests.

**Hook executable tests:**

- Drive `squish-hook` as a subprocess (or its core function) with fixture stdin +
  a stale heartbeat → asserts immediate passthrough (exit 0, no block).
- Fresh heartbeat + pre-seeded decision file → asserts it emits the correct
  hook-response JSON and cleans up.

**Manual / integration verification (documented steps for the "testable feature"):**

- Enable the feature, confirm hook merged into `~/.claude/settings.json` and
  Accessibility prompt appears.
- Run a Claude Code session in the monitored folder; trigger a tool that prompts
  for permission; confirm the notch opens vertically, Approve/Deny drives Claude.
- Trigger a question; type an answer; confirm it lands in the terminal (or
  clipboard-fallback).
- Two concurrent sessions → two tabs; resolve one → its tab closes; resolve both
  → notch collapses.
- Disable the feature → hook removed, sessions in a closed-Squish state proceed
  normally (passthrough).

## Implementation phasing (single spec, staged build)

1. Core wire format + spool + heartbeat + `HookSettings` + `LiveActivity`
   (+ their tests).
2. `squish-hook` executable (+ tests) and `Package.swift` target.
3. `AgentControlCenter` + `HookInstaller` + AppState wiring + "Live chats"
   section (permissions path end-to-end; answers stubbed).
4. Notch UI (compact / panel / prompt) + `LiveChatsNotchController`.
5. `TerminalResponder` keystroke write-path + clipboard fallback (free-text
   answers).
6. Verification pass: build, run tests, manual walkthrough.
