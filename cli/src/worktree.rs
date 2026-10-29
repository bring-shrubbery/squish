//! A linked worktree and the rules for flagging and removing it. These mirror the app's
//! `WorktreePolicy` (Sources/SquishCore/WorktreeModels.swift) so both make the same calls.

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// The coding agent that created a worktree, judged from where it lives.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Agent {
    ClaudeCode,
}

impl Agent {
    pub fn detect(path: &Path) -> Option<Agent> {
        path.to_string_lossy().contains("/.claude/worktrees/").then_some(Agent::ClaudeCode)
    }

    pub fn name(self) -> &'static str {
        match self {
            Agent::ClaudeCode => "Claude Code",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Worktree {
    pub path: PathBuf,
    /// The repo's main worktree.
    pub repo: PathBuf,
    /// None for a detached HEAD.
    pub branch: Option<String>,
    pub head: String,
    pub is_locked: bool,
    /// git reports the worktree's directory as missing.
    pub is_prunable: bool,
    pub last_activity: Option<SystemTime>,
    pub uncommitted: usize,
    pub unpushed: usize,
    /// Allocated bytes on disk; None when unmeasured.
    pub size_bytes: Option<u64>,
    /// Why git could not read this worktree's details; such a worktree is listed but not removable.
    pub detail_error: Option<String>,
}

impl Worktree {
    pub fn agent(&self) -> Option<Agent> {
        Agent::detect(&self.path)
    }

    pub fn display_name(&self) -> String {
        match &self.branch {
            Some(branch) => branch.clone(),
            None => format!("detached {}", &self.head[..self.head.len().min(7)]),
        }
    }

    pub fn repo_name(&self) -> String {
        self.repo.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
    }

    pub fn has_work(&self) -> bool {
        self.uncommitted > 0 || self.unpushed > 0
    }

    pub fn idle(&self, now: SystemTime) -> Option<Duration> {
        self.last_activity.map(|last| now.duration_since(last).unwrap_or_default())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Thresholds {
    pub max_age_days: u64,
    pub max_size_bytes: u64,
}

impl Default for Thresholds {
    fn default() -> Self {
        Thresholds { max_age_days: 14, max_size_bytes: 1_000_000_000 }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Flag {
    Stale { days: u64 },
    Large { bytes: u64 },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Removal {
    /// Clean: `git worktree remove`.
    Clean,
    /// Work exists only here: a second confirmation, then `git worktree remove --force`.
    LosesWork {
        uncommitted: usize,
        unpushed: usize,
        detached: bool,
    },
    Blocked(String),
    /// The directory is already gone: `git worktree prune`.
    Prune,
}

pub const ACTIVE_REASON: &str = "a process is working in this worktree";
pub const LOCKED_REASON: &str = "locked; run git worktree unlock to allow removal";

const DAY: u64 = 86_400;

/// Whether any of the processes' working directories is the worktree or inside it.
pub fn is_active(worktree: &Path, active_paths: &[PathBuf]) -> bool {
    active_paths.iter().any(|path| path.starts_with(worktree))
}

/// Past the age or size threshold. A missing or in-use worktree is never flagged.
pub fn flags(worktree: &Worktree, thresholds: Thresholds, active_paths: &[PathBuf], now: SystemTime) -> Vec<Flag> {
    if worktree.is_prunable || is_active(&worktree.path, active_paths) {
        return Vec::new();
    }
    let mut flags = Vec::new();
    if let Some(idle) = worktree.idle(now)
        && idle.as_secs() > thresholds.max_age_days * DAY
    {
        flags.push(Flag::Stale { days: idle.as_secs() / DAY });
    }
    if let Some(size) = worktree.size_bytes
        && size > thresholds.max_size_bytes
    {
        flags.push(Flag::Large { bytes: size });
    }
    flags
}

pub fn removal(worktree: &Worktree, active_paths: &[PathBuf]) -> Removal {
    if worktree.is_prunable {
        return Removal::Prune;
    }
    if let Some(error) = &worktree.detail_error {
        return Removal::Blocked(error.clone());
    }
    if is_active(&worktree.path, active_paths) {
        return Removal::Blocked(ACTIVE_REASON.into());
    }
    if worktree.is_locked {
        return Removal::Blocked(LOCKED_REASON.into());
    }
    if worktree.has_work() {
        return Removal::LosesWork {
            uncommitted: worktree.uncommitted,
            unpushed: worktree.unpushed,
            detached: worktree.branch.is_none(),
        };
    }
    Removal::Clean
}

/// The decision made immediately before `git worktree remove`, on counts just read from git:
/// None to proceed, otherwise why to refuse. A plain removal needs a clean, idle worktree; a
/// forced one may lose at most what the user confirmed.
pub fn fresh_removal_check(
    uncommitted: usize,
    unpushed: usize,
    active: bool,
    force: bool,
    confirmed_uncommitted: usize,
    confirmed_unpushed: usize,
) -> Option<String> {
    if active {
        return Some(ACTIVE_REASON.into());
    }
    if !force {
        return (uncommitted > 0 || unpushed > 0)
            .then(|| "it now has work in it; run clean again to review what would be lost".into());
    }
    (uncommitted > confirmed_uncommitted || unpushed > confirmed_unpushed)
        .then(|| "it has more work in it than you confirmed; run clean again to review".into())
}

/// What removing a chosen set of worktrees would do, from the last scan. Removal re-checks
/// each one against git right before deleting it.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Plan {
    pub clean: Vec<Worktree>,
    pub loses_work: Vec<Worktree>,
    pub prune: Vec<Worktree>,
    pub skipped: Vec<(Worktree, String)>,
}

impl Plan {
    pub fn new(worktrees: impl IntoIterator<Item = Worktree>, active_paths: &[PathBuf]) -> Plan {
        let mut plan = Plan::default();
        for worktree in worktrees {
            match removal(&worktree, active_paths) {
                Removal::Clean => plan.clean.push(worktree),
                Removal::LosesWork { .. } => plan.loses_work.push(worktree),
                Removal::Prune => plan.prune.push(worktree),
                Removal::Blocked(reason) => plan.skipped.push((worktree, reason)),
            }
        }
        plan
    }

    pub fn is_empty(&self) -> bool {
        self.clean.is_empty() && self.loses_work.is_empty() && self.prune.is_empty()
    }

    pub fn bytes(&self, include_work: bool) -> u64 {
        let work: &[Worktree] = if include_work { &self.loses_work } else { &[] };
        self.clean.iter().chain(work).filter_map(|w| w.size_bytes).sum()
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub fn worktree(path: &str) -> Worktree {
        Worktree {
            path: PathBuf::from(path),
            repo: PathBuf::from("/repo"),
            branch: Some("feature".into()),
            head: "0123456789abcdef".into(),
            is_locked: false,
            is_prunable: false,
            last_activity: None,
            uncommitted: 0,
            unpushed: 0,
            size_bytes: None,
            detail_error: None,
        }
    }

    fn days_ago(now: SystemTime, days: u64) -> Option<SystemTime> {
        Some(now - Duration::from_secs(days * DAY))
    }

    #[test]
    fn flags_old_and_large_worktrees_but_not_busy_or_missing_ones() {
        let now = SystemTime::now();
        let mut old = worktree("/wt/old");
        old.last_activity = days_ago(now, 20);
        old.size_bytes = Some(2_000_000_000);
        assert_eq!(
            flags(&old, Thresholds::default(), &[], now),
            [Flag::Stale { days: 20 }, Flag::Large { bytes: 2_000_000_000 }]
        );

        let mut fresh = worktree("/wt/fresh");
        fresh.last_activity = days_ago(now, 3);
        fresh.size_bytes = Some(10);
        assert!(flags(&fresh, Thresholds::default(), &[], now).is_empty());

        assert!(flags(&old, Thresholds::default(), &[PathBuf::from("/wt/old/src")], now).is_empty());
        let mut missing = old.clone();
        missing.is_prunable = true;
        assert!(flags(&missing, Thresholds::default(), &[], now).is_empty());
    }

    #[test]
    fn activity_matches_whole_path_components() {
        assert!(is_active(Path::new("/wt/a"), &[PathBuf::from("/wt/a")]));
        assert!(is_active(Path::new("/wt/a"), &[PathBuf::from("/wt/a/b")]));
        assert!(!is_active(Path::new("/wt/a"), &[PathBuf::from("/wt/ab")]));
        assert!(!is_active(Path::new("/wt/a"), &[PathBuf::from("/wt")]));
    }

    #[test]
    fn removal_decisions() {
        let clean = worktree("/wt/a");
        assert_eq!(removal(&clean, &[]), Removal::Clean);
        assert_eq!(removal(&clean, &[PathBuf::from("/wt/a")]), Removal::Blocked(ACTIVE_REASON.into()));

        let mut locked = clean.clone();
        locked.is_locked = true;
        assert_eq!(removal(&locked, &[]), Removal::Blocked(LOCKED_REASON.into()));

        let mut dirty = clean.clone();
        dirty.branch = None;
        dirty.unpushed = 2;
        assert_eq!(removal(&dirty, &[]), Removal::LosesWork { uncommitted: 0, unpushed: 2, detached: true });

        let mut gone = dirty.clone();
        gone.is_prunable = true;
        assert_eq!(removal(&gone, &[PathBuf::from("/wt/a")]), Removal::Prune);

        let mut unreadable = clean.clone();
        unreadable.detail_error = Some("boom".into());
        assert_eq!(removal(&unreadable, &[]), Removal::Blocked("boom".into()));
    }

    #[test]
    fn fresh_check_refuses_new_work() {
        assert_eq!(fresh_removal_check(0, 0, false, false, 0, 0), None);
        assert!(fresh_removal_check(1, 0, false, false, 0, 0).is_some());
        assert!(fresh_removal_check(0, 0, true, true, 9, 9).is_some());
        assert_eq!(fresh_removal_check(2, 1, false, true, 2, 1), None);
        assert!(fresh_removal_check(3, 1, false, true, 2, 1).is_some());
    }

    #[test]
    fn plans_sort_worktrees_by_what_removal_does() {
        let mut dirty = worktree("/wt/dirty");
        dirty.uncommitted = 1;
        dirty.size_bytes = Some(5);
        let mut clean = worktree("/wt/clean");
        clean.size_bytes = Some(10);
        let mut gone = worktree("/wt/gone");
        gone.is_prunable = true;
        let busy = worktree("/wt/busy");
        let plan = Plan::new([dirty, clean, gone, busy], &[PathBuf::from("/wt/busy")]);
        assert_eq!(plan.clean.len(), 1);
        assert_eq!(plan.loses_work.len(), 1);
        assert_eq!(plan.prune.len(), 1);
        assert_eq!(plan.skipped.len(), 1);
        assert_eq!(plan.bytes(false), 10);
        assert_eq!(plan.bytes(true), 15);
    }
}
