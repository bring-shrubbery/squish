//! Collecting the worktrees under a folder and printing what was found.

use std::cmp::Reverse;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;

use crate::git::{Git, GitError};
use crate::paths::{display, normalized};
use crate::scan::{self, RepoScan};
use crate::style::{self, Paint, Progress};
use crate::worktree::{self, Flag, Removal, Thresholds, Worktree};
use crate::{procs, size};

#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
pub enum SortKey {
    Size,
    Age,
    Name,
    Repo,
}

pub struct ScanOptions {
    pub root: PathBuf,
    pub depth: usize,
    pub measure: bool,
    pub thresholds: Thresholds,
}

/// One worktree with what squish concluded about it.
#[derive(Debug, Clone)]
pub struct Entry {
    pub worktree: Worktree,
    pub flags: Vec<Flag>,
    pub active: bool,
    pub removal: Removal,
}

pub struct Report {
    pub root: PathBuf,
    pub repos: Vec<RepoScan>,
    pub entries: Vec<Entry>,
    pub active_paths: Vec<PathBuf>,
    pub thresholds: Thresholds,
    pub now: SystemTime,
}

pub fn collect(git: &dyn Git, options: &ScanOptions, progress: &Progress) -> Result<Report, GitError> {
    let root = normalized(&options.root);
    progress.update(|| format!("Looking for repos under {}", display(&root)));
    let repo_paths = scan::repos(git, &root, options.depth)?;
    let mut repos = scan::scan(git, &repo_paths, &|done, total| {
        progress.update(|| format!("Reading worktrees {done}/{total} in {} repos", repo_paths.len()))
    });
    if options.measure {
        let paths: Vec<PathBuf> = repos.iter().flat_map(|r| r.worktrees.iter().map(|w| w.path.clone())).collect();
        let sizes = size::measure_all(&paths, &|so_far| {
            progress.update(|| format!("Measuring {} worktrees · {}", paths.len(), style::bytes(so_far)))
        });
        let mut sizes = sizes.into_iter();
        for worktree in repos.iter_mut().flat_map(|r| r.worktrees.iter_mut()) {
            worktree.size_bytes = sizes.next().flatten();
        }
    }
    progress.update(|| "Checking which worktrees are in use".into());
    let active_paths = procs::active_paths();
    progress.clear();
    let now = SystemTime::now();
    let entries = repos
        .iter()
        .flat_map(|r| r.worktrees.iter())
        .map(|w| entry(w.clone(), options.thresholds, &active_paths, now))
        .collect();
    Ok(Report { root, repos, entries, active_paths, thresholds: options.thresholds, now })
}

pub fn entry(worktree: Worktree, thresholds: Thresholds, active_paths: &[PathBuf], now: SystemTime) -> Entry {
    Entry {
        flags: worktree::flags(&worktree, thresholds, active_paths, now),
        active: worktree::is_active(&worktree.path, active_paths),
        removal: worktree::removal(&worktree, active_paths),
        worktree,
    }
}

impl Entry {
    pub fn is_stale(&self) -> bool {
        self.flags.iter().any(|f| matches!(f, Flag::Stale { .. }))
    }

    pub fn is_large(&self) -> bool {
        self.flags.iter().any(|f| matches!(f, Flag::Large { .. }))
    }

    pub fn is_flagged(&self) -> bool {
        !self.flags.is_empty()
    }

    /// Short coloured notes: missing, in use, stale, large, work, agent, error.
    pub fn notes(&self, paint: &Paint) -> Vec<String> {
        let w = &self.worktree;
        let mut notes = Vec::new();
        if w.is_prunable {
            notes.push(paint.yellow("directory missing"));
        }
        if let Some(error) = &w.detail_error {
            notes.push(paint.red(format!("unreadable: {}", style::truncate(error.lines().next().unwrap_or(""), 50))));
        }
        if self.active {
            notes.push(paint.cyan("in use"));
        }
        if w.is_locked {
            notes.push(paint.dim("locked"));
        }
        if self.is_stale() {
            notes.push(paint.yellow("stale"));
        }
        if self.is_large() {
            notes.push(paint.yellow("large"));
        }
        if w.uncommitted > 0 {
            notes.push(paint.magenta(format!("{} uncommitted", w.uncommitted)));
        }
        if w.unpushed > 0 {
            notes.push(paint.magenta(format!("{} unpushed", w.unpushed)));
        }
        if let Some(agent) = w.agent() {
            notes.push(paint.blue(agent.name()));
        }
        notes
    }
}

pub fn sort(entries: &mut [Entry], key: SortKey) {
    match key {
        SortKey::Size => entries.sort_by_key(|e| Reverse(e.worktree.size_bytes)),
        SortKey::Age => entries.sort_by_key(|e| e.worktree.last_activity.unwrap_or(SystemTime::now())),
        SortKey::Name => entries.sort_by_key(|e| e.worktree.display_name().to_lowercase()),
        SortKey::Repo => entries.sort_by_key(|e| (e.worktree.repo_name().to_lowercase(), e.worktree.display_name())),
    }
}

impl Report {
    pub fn total_bytes(&self) -> u64 {
        self.entries.iter().filter_map(|e| e.worktree.size_bytes).sum()
    }

    /// Flagged and removable without losing work.
    pub fn reclaimable(&self) -> (usize, u64) {
        let clean: Vec<&Entry> =
            self.entries.iter().filter(|e| e.is_flagged() && e.removal == Removal::Clean).collect();
        (clean.len(), clean.iter().filter_map(|e| e.worktree.size_bytes).sum())
    }
}

pub fn print_header(report: &Report, paint: &Paint, measured: bool) {
    let worktrees = report.entries.len();
    let repos = report.repos.len();
    println!();
    println!(" {}  {}", paint.purple_bold("squish"), paint.bold(format!("worktrees under {}", display(&report.root))));
    let mut summary = format!(
        " {} {} · {} linked {}",
        repos,
        if repos == 1 { "repo" } else { "repos" },
        worktrees,
        if worktrees == 1 { "worktree" } else { "worktrees" }
    );
    if measured {
        summary.push_str(&format!(" · {} on disk", style::bytes(report.total_bytes())));
    }
    println!("{}", paint.dim(summary));
}

pub fn print_text(report: &Report, sort_key: SortKey, only_flagged: bool, paint: &Paint, measured: bool) {
    print_header(report, paint, measured);
    let width = style::terminal_width();
    let largest = report.entries.iter().filter_map(|e| e.worktree.size_bytes).max().unwrap_or(0);

    // Repos ordered by the space their worktrees take, then name.
    let mut repos: Vec<&RepoScan> = report.repos.iter().collect();
    let repo_bytes = |repo: &Path| -> u64 {
        report.entries.iter().filter(|e| e.worktree.repo == repo).filter_map(|e| e.worktree.size_bytes).sum()
    };
    repos.sort_by_key(|r| (Reverse(repo_bytes(&r.repo)), r.repo.clone()));

    let name_width = report
        .entries
        .iter()
        .map(|e| e.worktree.display_name().chars().count())
        .max()
        .unwrap_or(10)
        .clamp(10, (width / 3).max(16));
    let mut shown = 0;
    for repo in repos {
        let mut entries: Vec<Entry> = report
            .entries
            .iter()
            .filter(|e| e.worktree.repo == repo.repo && (!only_flagged || e.is_flagged()))
            .cloned()
            .collect();
        if entries.is_empty() && repo.error.is_none() {
            continue;
        }
        sort(&mut entries, sort_key);
        println!();
        println!(
            " {} {}  {}",
            paint.purple_bold("➤"),
            paint.bold(repo_name(&repo.repo)),
            paint.dim(display(&repo.repo))
        );
        if let Some(error) = &repo.error {
            println!("   {} {}", paint.red("✗"), paint.red(error));
        }
        for e in &entries {
            shown += 1;
            let w = &e.worktree;
            let name = style::pad(&style::truncate(&w.display_name(), name_width), name_width);
            let size = match w.size_bytes {
                Some(bytes) => format!("{:>8}", style::bytes(bytes)),
                None => format!("{:>8}", "—"),
            };
            let (full, empty) = style::bar(w.size_bytes.unwrap_or(0), largest, 10);
            let age = w.idle(report.now).map(style::ago).unwrap_or_else(|| "—".into());
            let marker = match e.removal {
                Removal::Blocked(_) => paint.dim("·"),
                _ if e.is_flagged() || w.is_prunable => paint.yellow("●"),
                _ => paint.green("●"),
            };
            let bar =
                if measured { format!("  {}{}", paint.purple_bold(full), paint.dim(empty)) } else { String::new() };
            let size = if measured { format!("  {size}") } else { String::new() };
            println!(
                "   {marker} {name}{size}{bar}  {}  {}",
                style::pad(&age, 14),
                e.notes(paint).join(&paint.dim(" · "))
            );
        }
    }
    if shown == 0 {
        println!();
        if only_flagged {
            println!(" {} Nothing past the thresholds.", paint.green("✓"));
        } else {
            println!(" {} No linked worktrees here.", paint.green("✓"));
        }
    }

    println!();
    println!("{}", paint.dim(format!(" {}", "─".repeat(width.saturating_sub(2).min(72)))));
    let (count, bytes) = report.reclaimable();
    let rule = format!(
        "idle over {} days{}",
        report.thresholds.max_age_days,
        if measured { format!(" or over {}", style::bytes(report.thresholds.max_size_bytes)) } else { String::new() }
    );
    if count > 0 {
        let amount = if measured { format!("{} in ", style::bytes(bytes)) } else { String::new() };
        println!(
            " {}  {}{} clean {} past the thresholds ({rule})",
            paint.bold("Reclaimable"),
            paint.green(amount),
            count,
            if count == 1 { "worktree" } else { "worktrees" }
        );
        println!(" {}         {}  remove those", paint.bold("Next"), paint.cyan("squish clean --flagged"));
        println!("              {}  pick interactively", paint.cyan(style::pad("squish clean", 22)));
    } else {
        println!(" {}  nothing clean is past the thresholds ({rule})", paint.bold("Reclaimable"));
        if !report.entries.is_empty() {
            println!(" {}         {}  pick worktrees to remove", paint.bold("Next"), paint.cyan("squish clean"));
        }
    }
    println!();
}

fn repo_name(repo: &Path) -> String {
    repo.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| repo.display().to_string())
}

#[derive(Serialize)]
struct JsonReport<'a> {
    root: String,
    thresholds: JsonThresholds,
    total_bytes: Option<u64>,
    repos: Vec<JsonRepo>,
    worktrees: Vec<JsonWorktree<'a>>,
}

#[derive(Serialize)]
struct JsonThresholds {
    stale_days: u64,
    large_bytes: u64,
}

#[derive(Serialize)]
struct JsonRepo {
    path: String,
    worktrees: usize,
    error: Option<String>,
}

#[derive(Serialize)]
struct JsonWorktree<'a> {
    path: String,
    repo: String,
    branch: Option<&'a str>,
    head: &'a str,
    size_bytes: Option<u64>,
    /// Unix seconds.
    last_activity: Option<u64>,
    uncommitted: usize,
    unpushed: usize,
    locked: bool,
    missing: bool,
    in_use: bool,
    stale: bool,
    large: bool,
    agent: Option<&'static str>,
    /// clean, loses_work, prune or blocked.
    removal: &'static str,
    blocked_reason: Option<&'a str>,
    error: Option<&'a str>,
}

pub fn print_json(report: &Report, sort_key: SortKey, only_flagged: bool, measured: bool) {
    let mut entries: Vec<Entry> = report.entries.iter().filter(|e| !only_flagged || e.is_flagged()).cloned().collect();
    sort(&mut entries, sort_key);
    let worktrees = entries
        .iter()
        .map(|e| {
            let w = &e.worktree;
            let (removal, blocked_reason) = match &e.removal {
                Removal::Clean => ("clean", None),
                Removal::LosesWork { .. } => ("loses_work", None),
                Removal::Prune => ("prune", None),
                Removal::Blocked(reason) => ("blocked", Some(reason.as_str())),
            };
            JsonWorktree {
                path: w.path.display().to_string(),
                repo: w.repo.display().to_string(),
                branch: w.branch.as_deref(),
                head: &w.head,
                size_bytes: w.size_bytes,
                last_activity: w.last_activity.and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs()),
                uncommitted: w.uncommitted,
                unpushed: w.unpushed,
                locked: w.is_locked,
                missing: w.is_prunable,
                in_use: e.active,
                stale: e.is_stale(),
                large: e.is_large(),
                agent: w.agent().map(|a| a.name()),
                removal,
                blocked_reason,
                error: w.detail_error.as_deref(),
            }
        })
        .collect();
    let json = JsonReport {
        root: report.root.display().to_string(),
        thresholds: JsonThresholds {
            stale_days: report.thresholds.max_age_days,
            large_bytes: report.thresholds.max_size_bytes,
        },
        total_bytes: measured.then(|| report.total_bytes()),
        repos: report
            .repos
            .iter()
            .map(|r| JsonRepo {
                path: r.repo.display().to_string(),
                worktrees: r.worktrees.len(),
                error: r.error.clone(),
            })
            .collect(),
        worktrees,
    };
    println!("{}", serde_json::to_string_pretty(&json).expect("the report serializes"));
}
