# Worktree cleanup — design

Date: 2026-10-04
Status: approved in conversation, awaiting spec review

## Goal

Coding agents leave git worktrees behind (Claude Code under `<repo>/.claude/worktrees/`,
others wherever they like), and each can hold gigabytes of build output and dependencies.
Squish gets a **Worktrees** section that finds every linked worktree under the watched
folder, shows how old and how big each one is, and removes stale ones without losing work.

Success: a user opening the section sees every linked worktree of the repos under their
folder, the ones past the age or size threshold are obvious, and removing one never
destroys uncommitted or unpushed work without an explicit, specific confirmation.

## Decisions

| Question | Decision |
| --- | --- |
| Which worktrees | All linked git worktrees of repos under the watched folder (`git worktree list`), whoever created them. Agent-made ones are labelled. |
| What cleanup does | `git worktree remove`, keeping the branch. Clean worktrees: one confirmation. Uncommitted changes or unpushed commits: a second confirmation naming what would be lost, then `--force`. |
| How flagged ones surface | A list highlighting worktrees past the thresholds, and a sidebar badge with their count. No notch alerts, no automatic removal. |
| Age | Time since last activity: the later of the HEAD commit date and the modification date of the worktree's git index (the last git operation in it). |
| Thresholds | 14 days and 1 GB by default, adjustable, saved in UserDefaults. A worktree is flagged when it passes either. |
| Active sessions | A worktree containing the working directory of a live agent session, or of any running process the user can inspect (shells, editors, agents keeping worktrees anywhere, read with libproc), is never flagged and cannot be removed. |
| Implementation | Shell out to the `git` command line. Not reading `.git/worktrees` directly (fragile; removal needs git anyway), not libgit2 (heavy dependency). |

Out of scope: the main worktree of a repo (never listed or removed), deleting branches,
notch alerts, automatic cleanup, repos outside the watched folder. Linked worktrees of an
in-folder repo are listed wherever they live (Codex, for example, keeps its worktrees under
`~/.codex/worktrees`).

## Discovery and data

**Repos.** A shallow walk of the watched folder (depth 4) collects directories containing
`.git`, skipping `node_modules`, `.build`, `DerivedData`, `Pods`, `vendor`, `dist`, `build`,
`.venv`, `target` and any hidden directory other than `.claude`. The git roots of every
session Squish tracks are added, so deeper repos are not missed. Linked worktrees of a repo
are found through that repo, so a worktree that is itself found by the walk is attributed to
its main repo, not treated as a separate one.

**Worktree.** For each linked worktree (`git worktree list --porcelain`, excluding the main
one):

- path, repo (main worktree path), branch (or detached HEAD and its short SHA)
- `locked` and `prunable` as reported by git
- last activity (above)
- size in bytes: allocated size on disk of every file, measured at low priority and cached
  by path and the worktree's last-activity date; `nil` while measuring or if it fails
- uncommitted changes: the count of entries in `git status --porcelain` (untracked included)
- unpushed commits: commits reachable from HEAD that are on no remote-tracking ref and on no
  other local branch (`git rev-list --count HEAD --not --exclude=<branch>
  --branches --remotes`; git matches `--exclude` for `--branches` relative to `refs/heads/`), so a fresh worktree branched from `main` in a repo without a
  remote counts zero, and only work that exists nowhere else counts
- agent: "Claude Code" for paths under `/.claude/worktrees/`, otherwise none
- in use: a tracked live session's or a running process's working directory is the worktree
  path or inside it

A prunable worktree (its directory is gone) is shown with a "Missing" chip and only offers
pruning.

**Refresh.** On opening the section, on the Refresh button, and hourly in the background so
the badge stays current. git work and sizing run off the main actor.

## UI

A new sidebar section **Worktrees** (`AppSection.worktrees`) with a badge showing the
flagged count when it is above zero.

**Header:** total disk used by linked worktrees, the flagged total, how many of the
worktrees the filter shows, the two thresholds as editable controls (age in days, size in GB)
and Refresh.

**Filter bar** (`WorktreeFilter`, kept in the store so it survives leaving the section): a
search over branch and path; a sort (largest, oldest, newest, name); and for each of
*Flagged*, *In use*, *Unsaved work* (uncommitted or unpushed), *Agent-made*, *Locked* and
*Missing* a three-way choice: any, only, hide. A minimum size (100 MB … 10 GB; unmeasured
worktrees drop out) and a minimum idle time (1 day … 3 months; worktrees with no known
activity drop out). "Reset filters" appears whenever anything is set. Every control is at
its default shows everything.

**Selection:** each row has a checkbox, each repo card a checkbox for its shown rows, and a
selection bar above the list one for everything shown (mixed state when only some are
selected). Rows whose removal is blocked (in use, locked, unreadable) cannot be selected and
say why on hover. The bar shows the count and size selected, notes how many selected rows the
filter currently hides, offers *Select ▸ All shown / Flagged shown / None*, and *Remove N
selected*. The selection drops paths that disappear from a scan.

**List:** grouped by repo, rows in the chosen order (largest first by default). A row shows
the branch and path, the agent label, last activity ("3 weeks ago"), size ("Measuring…" until
known), and chips for *Uncommitted changes*, *Unpushed commits*, *In use*, *Locked*, *Missing*.
Rows past a threshold are highlighted and say which threshold; selected rows are tinted. A
repo card says how many of its worktrees the filter hides. Actions: Reveal in Finder, Open in
Terminal, Remove.

The section follows the existing dark dashboard style (`AppColors`, the cards and rows of
`CostDashboardView`).

## Removal

`WorktreePolicy.removal(for:)` returns one of:

- `.confirm` — clean: "Remove `feature-x` (2.3 GB)? The branch `feature-x` is kept."
  Runs `git worktree remove <path>`.
- `.confirmLosingWork(uncommitted:unpushed:)` — the first confirmation lists what would be
  lost ("4 uncommitted changes (files or folders) will be deleted. 2 commits are on no remote; they stay on
  branch `feature-x`."), and a second "Remove anyway" runs `git worktree remove --force <path>`.
  A detached HEAD's HEAD reflog lives in `.git/worktrees/<id>/logs/HEAD`, which
  `git worktree remove` deletes, so before a forced removal of a detached HEAD with unpushed
  commits Squish creates a branch `squish/rescued-<short sha>` at that HEAD (suffixed `-2`,
  `-3`… if taken), and the confirmation says the commits will be saved on that new branch.
- `.blocked(reason:)` — a live session or a process is working in it, it is locked, or git
  could not read it. The button is disabled
  with the reason.
- `.pruneOnly` — the directory is missing; runs `git worktree prune`.

**Remove selected** acts on the selection through a `WorktreeBulkPlan`
(`WorktreePolicy.bulkPlan`), which sorts each chosen worktree into *clean* (`.confirm`),
*losing work* (`.confirmLosingWork`), *prune* (`.pruneOnly`) or *skipped* (`.blocked`). The
first confirmation names each group and the total space. When nothing chosen has work in it,
one button removes them. Otherwise it offers "Remove N without work" and "Remove all M…";
the latter leads to a second confirmation that lists, per worktree, exactly what is lost
(the same text as a single removal), and runs the forced removals with those counts as the
confirmed maximum. Prunes run first, then clean removals, then forced ones; each is its own
git run and re-checks the worktree first, so one failure never stops the rest. The skipped
ones are named afterwards.

Immediately before `git worktree remove`, off the main actor, Squish re-reads the worktree
from git (still listed, not locked, same branch, uncommitted and unpushed counts) and
re-probes live sessions and process working directories. A plain removal is refused unless
both counts are 0 and nothing is working in it; a forced one is refused if either count
exceeds what the user confirmed or something is working in it. A bulk removal applies the
plain check to each clean worktree and the forced check to each one whose loss was confirmed. `git worktree remove` and `git worktree prune` run without a
timeout; reads keep the 15-second timeout (SIGTERM, then SIGKILL after 2 s).

After any removal Squish runs `git worktree prune` in that repo, re-reads that repo, and
shows the reclaimed space briefly. When git fails, its stderr is shown on the row and the
repo is re-read; nothing is assumed.

## Architecture

SquishCore (pure and testable):

- `WorktreeModels.swift` — `Worktree`, `WorktreeThresholds`, `WorktreeFlag` (age, size),
  and `WorktreePolicy`: `flags(for:thresholds:activeSessionPaths:now:)` and
  `removal(for:activeSessionPaths:)`.
- `GitClient.swift` — protocol `GitClient` (`listWorktrees(repo:)`, `status(worktree:)`,
  `unpushedCount(worktree:)`, `headCommitDate(worktree:)`, `remove(worktree:force:)`,
  `prune(repo:)`) and `ProcessGitClient`, which runs `/usr/bin/git` with a 15-second timeout.
  `GitPorcelain` holds the pure parsers for `worktree list --porcelain` and
  `status --porcelain`.
- `RepoDiscovery.swift` — the shallow walk and the session-root merge.
- `DirectorySizer.swift` — allocated-size enumeration with a cache.
- `WorktreeScanner.swift` — produces `[Worktree]` per repo from the above, concurrently
  across repos with a small limit.

SquishApp:

- `WorktreeStore` (new `ObservableObject`) — the list, refresh scheduling, thresholds,
  remove actions and the flagged count. `AppState` stays as it is apart from handing the
  store the watched folder and the live session paths.
- `WorktreesView.swift` — the section; `AppSection.worktrees` and the sidebar badge.

## Error handling

- git missing (`/usr/bin/git` fails because the command line tools are not installed): the
  section shows how to install them (`xcode-select --install`); the rest of Squish is
  unaffected.
- A git command fails or times out for one repo: that repo shows an error row; the others
  list normally.
- Sizing fails: size shows "—" and the worktree is judged on age only.
- Removal fails: git's message on the row, then a re-read of that repo.

## Testing

Unit tests (SquishCoreTests):

- `GitPorcelain`: captured `worktree list --porcelain` output with a main worktree, linked
  branches, a detached HEAD, a locked and a prunable worktree, and paths with spaces;
  `status --porcelain` with modified, staged, untracked and renamed entries.
- `WorktreePolicy`: age and size flags at and around both thresholds, the session-active
  override, every `removal` case.
- `RepoDiscovery`: excluded directories are skipped, depth is honoured, session roots merge
  without duplicates.

Integration tests against real git in a temporary directory:

- a repo with two worktrees is scanned with the right branches, dirty count and unpushed
  count;
- removing a clean worktree deletes its directory and keeps its branch;
- a non-forced remove of a dirty worktree fails and leaves it in place; a forced one removes
  it and keeps the branch.

Manual: run the app against `~/Projects` (widget-ai currently has three Claude Code
worktrees) and check sizes against `du -sh`.
