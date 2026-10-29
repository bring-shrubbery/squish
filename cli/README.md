# squish CLI

**Find the git worktrees your coding agents left behind, and clean them up safely.**

`squish` is the command-line companion to the [Squish](../README.md) menu bar app. Version 0.0.1 does one thing: worktree analysis and cleanup. It looks for git repos under a folder, lists their linked worktrees with their size, last activity and any work that exists only there, and removes the ones you choose with `git worktree remove`, keeping their branches. It follows the same safety rules as the app's Worktrees page.

## Install

```sh
brew install bring-shrubbery/tap/squish
```

Prebuilt binaries for macOS and Linux (arm64 and x86_64) are also attached to every [`cli-v*` release](https://github.com/bring-shrubbery/squish/releases). To build from source, install Rust and run `cargo install --path cli` from a clone of this repo.

## Use

```sh
squish                     # the same as squish analyze .
squish analyze ~/Projects  # list every linked worktree under ~/Projects
squish clean ~/Projects    # pick worktrees to remove in an interactive list
squish clean --flagged     # remove the stale and large ones, after asking
squish clean --stale --dry-run   # show what would go, remove nothing
```

`analyze` groups worktrees by repo, largest first, with a size bar, how long ago anything happened in each, and notes: **stale** (no commit or index change in 14 days), **large** (over 1 GB), **in use** (a shell, editor or agent has its working directory there), **locked**, **directory missing**, uncommitted and unpushed counts, and **Claude Code** for worktrees under `.claude/worktrees`. It ends with what's reclaimable and the command to reclaim it. `--json` prints the same as JSON for scripts.

`clean` with no choice opens a list on the terminal: `↑`/`↓` (or `j`/`k`) to move, `space` to select, `f` for the flagged ones, `a` for all, `n` for none, `s` to change the order, `enter` to review, `q` to quit. Flagged worktrees that can go without losing anything start selected. It then shows the plan and asks before removing anything.

### Options

| | |
|---|---|
| `PATH` | The folder to search; defaults to the current one. A folder inside a repo finds that repo too. |
| `--depth N` | How many folder levels below `PATH` to look for repos (4). |
| `--stale-after DAYS` | Idle days before a worktree counts as stale (14). |
| `--large-over SIZE` | Size above which a worktree counts as large, such as `500MB` or `2GB` (1GB). |
| `--no-size` | Skip measuring sizes. |
| `--color auto\|always\|never` | Colours; `NO_COLOR` is respected. |

`analyze` also takes `--flagged` (only stale or large), `--sort size|age|name|repo` and `--json`. `clean` takes the choosers `--flagged`, `--stale`, `--large`, `--missing` and `--all`, plus `--dry-run` (`-n`), `--yes` (`-y`, don't ask) and `--force`.

## What it will and won't remove

- **A clean worktree** is removed with `git worktree remove`. Its branch stays.
- **A worktree with work found nowhere else** (uncommitted changes, or commits on no remote and no other branch) needs a second yes, or `--force` when you pass `--yes`. Uncommitted changes are deleted; commits stay on the worktree's branch. A detached HEAD's commits are first saved on a `squish/rescued-<sha>` branch.
- **A worktree whose directory is gone** is pruned with `git worktree prune`, which clears every unlocked missing worktree record in that repo.
- **Never removed:** a worktree any process is working in, a locked one, or one git can't read.

Right before each removal squish reads the worktree again from git and checks the running processes once more. If it changed branch, gained work you didn't confirm, or something started working in it, squish keeps it and says why.

Off a terminal, `clean` needs a chooser and `--yes`; without them it explains and exits non-zero, so a script never removes anything by accident.

## Exit codes

`0` done, `1` something failed or needs `--yes`, `2` a usage error.

## Develop

```sh
cd cli
cargo test                 # unit tests and end-to-end tests against real git repos
cargo clippy --all-targets -- -D warnings
cargo run -- analyze ~/Projects
```

Releases are cut by `.github/workflows/cli-release.yml` when the version in `Cargo.toml` changes; see [docs/release.md](../docs/release.md#the-squish-cli).
