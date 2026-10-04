# Squish

Squish is a local macOS app for monitoring coding-agent sessions inside a selected folder.

**Website:** https://squish.quassum.com · **Download:** [latest release](https://github.com/bring-shrubbery/squish/releases/latest)

## Install

Download `Squish-vX.Y.Z-macos-arm64.dmg` from the [latest release](https://github.com/bring-shrubbery/squish/releases/latest),
open it and drag Squish into Applications. Releases are signed with a Developer ID and
notarized by Apple. Squish needs macOS 14 or later on Apple silicon.

Squish updates itself: it checks for new versions automatically through
[Sparkle](https://sparkle-project.org), and **Squish → Check for Updates…** checks on demand.

## Included

- Onboarding with a persistent folder selection.
- Automatic Codex, Claude Code, and best-effort Gemini CLI discovery.
- Folder matching via each session's working directory, including nested projects.
- Per-session token and API-equivalent cost breakdowns.
- Durable cost ledger that preserves totals after source session logs are deleted.
- Per-day cost buckets keep completed days immutable while the active day updates live.
- Input, cache-read, cache-write, and output pricing.
- Long-context pricing tiers where providers use them.
- Real-time filesystem-event monitoring of changed session logs.
- Session-specific notch alerts at a configurable context threshold.
- Alert re-arming after a session compacts below the threshold.

Everything is parsed locally. No session content is uploaded.

## Performance model

- macOS filesystem events wake Squish only when agent logs change.
- Project membership is resolved once and cached instead of rescanning every log.
- Growing Codex and Claude logs are parsed from newly appended bytes only.
- Large logs are streamed in bounded chunks instead of loaded fully into memory.
- Recent sessions appear first while older history indexes in low-priority batches.
- Parsed summaries persist between launches for fast warm starts.
- Cost calculations are persisted and refreshed only when session usage changes.
- Unchanged session arrays are not republished to SwiftUI.
- A low-priority 30-second discovery pass catches newly created log locations.

## Run during development

    swift run Squish

## Test

    swift test

## Build the app bundle

    ./scripts/build-app.sh

The result is written to dist/Squish.app. The development bundle is ad-hoc signed.
Releases are built, signed, notarized and published automatically from `main`; see
[docs/release.md](docs/release.md).

## Session sources

- Codex: ~/.codex/sessions
- Claude Code: ~/.claude/projects
- Gemini CLI: ~/.gemini/tmp project chat folders
- Matching local .codex, .claude, and .gemini folders below the selected root

Squish is intentionally not sandboxed in this initial direct-distribution build because agent logs live in hidden home-directory folders. A Mac App Store build would need separate user grants for those locations.

## Pricing

The catalog is versioned in Sources/SquishCore/PricingCatalog.swift and currently marked 10 July 2026. Sources:

- OpenAI model pricing: https://developers.openai.com/api/docs/models
- Anthropic model pricing: https://platform.claude.com/docs/en/about-claude/pricing
- Gemini API pricing: https://ai.google.dev/gemini-api/docs/pricing

Values are API-equivalent estimates. Codex, Claude, or Gemini subscription billing can differ. Unknown model IDs remain visible but are excluded from estimated totals until a price is added.

## Contributing

Ideas and questions go to [Discussions](https://github.com/bring-shrubbery/squish/discussions),
reproduced bugs to [Issues](https://github.com/bring-shrubbery/squish/issues). Pull requests are
not accepted; [CONTRIBUTING.md](CONTRIBUTING.md) explains why.

## License

Squish is licensed under the [Apache License 2.0](LICENSE).
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) lists the third-party components
(DynamicNotchKit and Sparkle, both MIT).
