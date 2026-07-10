# Squish

Squish is a local macOS app for monitoring coding-agent sessions inside a selected folder.

## Included

- Onboarding with a persistent folder selection.
- Automatic Codex, Claude Code, and best-effort Gemini CLI discovery.
- Folder matching via each session's working directory, including nested projects.
- Per-session token and API-equivalent cost breakdowns.
- Input, cache-read, cache-write, and output pricing.
- Long-context pricing tiers where providers use them.
- One-second live monitoring of changed session logs.
- Session-specific notch alerts at a configurable context threshold.
- Alert re-arming after a session compacts below the threshold.

Everything is parsed locally. No session content is uploaded.

## Run during development

    swift run Squish

## Test

    swift test

## Build the app bundle

    ./scripts/build-app.sh

The result is written to dist/Squish.app. The development bundle is ad-hoc signed.

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
