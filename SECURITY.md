# Security

Squish runs entirely on your Mac. It reads coding-agent session logs on disk (`~/.codex/sessions`, `~/.claude/projects` and Gemini CLI's), and goes online only to check GitHub for a newer release through its update feed. No session content is uploaded.

The live chats install a Claude Code hook (`squish-hook`, inside the app bundle) in `~/.claude/settings.json` when you turn them on, and use the Accessibility permission to type your answers into the terminal. Both are opt-in and can be removed from the app's settings.

## Reporting a vulnerability

Please report security problems privately through GitHub's advisory form, not in a public issue:

https://github.com/bring-shrubbery/squish/security/advisories/new

Include what you found, how to reproduce it, and the Squish version or commit. You will get an acknowledgement within a few days and a fix or a reasoned response as soon as we have one. We will credit you in the release notes unless you ask us not to.

## Scope

In scope: the Squish app, the `squish-hook` executable and the Claude Code settings it writes, the update feed, the build scripts and the GitHub workflows in this repository.

Out of scope: the coding agents themselves (Claude Code, Codex, Gemini CLI), DynamicNotchKit and Sparkle (report upstream).
