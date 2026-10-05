<img src="Sources/SquishApp/Resources/AppIcon.png" align="right" width="128" alt="Squish icon">

# Squish

**Token costs, context alerts and live agent chats for your Mac.** Squish watches the Codex, Claude Code and Gemini CLI sessions in a folder you choose, shows what each one costs, warns you in the notch before a session's context compacts, and lets you answer Claude Code's permission prompts and questions without switching to the terminal. Everything is parsed locally; no session content is uploaded.

> [!NOTE]
> **Status: v0.1 (October 2026).** Download the latest release from [squish.quassum.com](https://squish.quassum.com) or the [Releases page](https://github.com/bring-shrubbery/squish/releases/latest). It is signed and notarized, and updates itself. macOS 14 or later on Apple silicon.

## What it does

- **Finds your agent sessions.** Pick a folder once. Squish discovers Codex and Claude Code sessions, and Gemini CLI sessions on a best-effort basis, whose working directory is inside it, including nested projects.
- **Shows what each session costs.** Tokens and API-equivalent cost per session, split into input, cache reads, cache writes and output, with long-context pricing tiers where providers charge them.
- **Keeps the totals.** A durable cost ledger preserves your spend after the agents delete their old logs. Completed days are frozen; today updates live.
- **Warns before context compacts.** When a session's context passes your threshold (80% by default, adjustable from 50% to 95%), a dark Dynamic Island style alert drops from the top of the screen. It re-arms once the session compacts below the threshold.
- **Puts live chats in the notch.** Optionally, active sessions grow the notch sideways, and a Claude Code permission request or question drops it open so you can allow, deny or answer right there.
- **Cleans up worktrees.** Lists every linked git worktree of the repos in your folder with its age and size, flags the ones older than 14 days or larger than 1 GB (both adjustable), and removes them with `git worktree remove`, keeping the branch. Worktrees with uncommitted or unpushed work need a second confirmation that says what would be lost.

## Install

Download `Squish-vX.Y.Z-macos-arm64.dmg` from the [latest release](https://github.com/bring-shrubbery/squish/releases/latest), open it and drag Squish into Applications.

Squish checks for updates automatically through [Sparkle](https://sparkle-project.org) and installs them after asking; **Squish → Check for Updates…** checks on demand. Every update is verified against Squish's signing key before it is installed.

## Usage

1. **Choose a folder.** On first launch, pick the folder that holds your projects (later: **File → Choose Project Folder…**, `⇧⌘O`). Squish remembers it.
2. **Read the costs.** Sessions appear newest first while older history indexes in the background. Each one shows its tokens, its estimated cost and how full its context is.
3. **Set the alert threshold.** Under **Compact alerts**, choose when the notch alert fires, or preview it.
4. **Turn on Live chats** if you want to answer Claude Code from the notch. Squish installs its hook (below); a preview button shows what a request looks like.
5. **Leave it running.** `⌘Q` closes the window and keeps Squish in the menu bar, where it goes on watching your sessions, so compact alerts and live chats work without the window. The menu bar icon shows how many sessions are active, reopens the window, and has the real **Quit Squish**. **Squish → Settings…** (`⌘,`) turns this off, so `⌘Q` quits, and can open Squish at login.

## Live chats and the Claude Code hook

With Live chats on, Claude Code permission prompts and `AskUserQuestion` questions open the notch with one tab per waiting session. Approve or deny a tool, pick one of the offered answers, or type your own.

- **One hook, nothing else.** Squish adds a single `PermissionRequest` hook to `~/.claude/settings.json` that runs `squish-hook`, a small program bundled inside the app. It backs up the original file once (`settings.json.squish-backup`), leaves your other hooks alone, and removes its entry when you turn Live chats off.
- **Only real prompts.** `PermissionRequest` fires only when Claude Code would actually ask you, so tools your permission mode already allows never reach the notch.
- **Never hangs a session.** The hook passes straight through to Claude Code's own prompt unless Squish is running and watching the session's folder, and falls back to that prompt after five minutes without an answer.
- **No surprise permissions.** Allow and deny need nothing from macOS. Accessibility is requested only the first time you send an answer to a question, so Squish can type it into the terminal; without it, the answer is copied to the clipboard.

Codex and Gemini CLI sessions appear as active chats too, but are answered in their own terminal. Turn Live chats off before deleting Squish, so the hook entry is removed.

## Where it looks

| Agent | Session logs | Support |
|---|---|---|
| Codex | `~/.codex/sessions` | Full |
| Claude Code | `~/.claude/projects` | Full, plus answering from the notch |
| Gemini CLI | `~/.gemini/tmp` | Best effort |

Squish also picks up matching local `.codex`, `.claude` and `.gemini` folders below the folder you chose. It is not sandboxed, because these logs live in hidden folders in your home directory; a Mac App Store build would need separate user grants for them.

## Pricing

Costs are API-equivalent estimates from the providers' published prices. The catalog is versioned in [`Sources/SquishCore/PricingCatalog.swift`](Sources/SquishCore/PricingCatalog.swift) (currently dated 5 October 2026), from:

- [OpenAI model pricing](https://developers.openai.com/api/docs/models)
- [Anthropic model pricing](https://platform.claude.com/docs/en/about-claude/pricing)
- [Gemini API pricing](https://ai.google.dev/gemini-api/docs/pricing)

Codex, Claude and Gemini subscriptions bill differently. Models without a known price stay visible but are left out of the totals until a price is added.

Prices update without waiting for an app update: every release publishes its catalog as `pricing.json`, signed with the same key as the app's updates, and Squish downloads it at launch and every six hours, checks the signature, and switches to it when it is newer than the catalog it shipped with. Stored sessions are re-priced at the new rates. The Costs page footer says which catalog is in use.

## How it stays light

- macOS filesystem events wake Squish only when agent logs change, with a low-priority 30-second pass to catch new log locations.
- Project membership is resolved once and cached instead of rescanning every log.
- Growing Codex and Claude logs are parsed from the newly appended bytes only; large logs are streamed in bounded chunks.
- Recent sessions appear first while older history indexes in low-priority batches.
- Parsed summaries and cost calculations persist between launches for fast warm starts, and are refreshed only when a session's usage changes.

## Build from source

Requires Xcode with the Swift 6 toolchain, on macOS 14 or later.

```sh
git clone https://github.com/bring-shrubbery/squish.git
cd squish
swift run Squish          # run during development
swift test                # the SquishCore tests
./scripts/build-app.sh    # dist/Squish.app, signed ad hoc
```

The package has three targets: `SquishCore` (session parsing, pricing, the cost ledger, hook settings), `SquishApp` (the SwiftUI app and the notch) and `SquishHook` (the `squish-hook` executable Claude Code runs). Releases are built, signed, notarized and published automatically from `main`; [docs/release.md](docs/release.md) explains the pipeline.

## Contributing

Squish is developed by a small team working with AI coding agents that we run and supervise ourselves. Because of that:

- **Feature requests, ideas and questions** go to [Discussions](https://github.com/bring-shrubbery/squish/discussions).
- **Bug reports** go to [Issues](https://github.com/bring-shrubbery/squish/issues), using the template, for bugs you have reproduced yourself.
- **Pull requests are not accepted** and are closed automatically.

[CONTRIBUTING.md](CONTRIBUTING.md) explains the reasoning. Security problems: see [SECURITY.md](SECURITY.md).

## License

Squish is licensed under the [Apache License 2.0](LICENSE). [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists the third-party components: [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) and [Sparkle](https://github.com/sparkle-project/Sparkle), both MIT.

Squish is by [Antoni Silvestrovic](https://github.com/bring-shrubbery) at [Quassum](https://quassum.com), built with Claude Code.
