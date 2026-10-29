//! `squish clean`: choose worktrees, show what removing them does, confirm, remove, report.

use std::collections::BTreeMap;
use std::ffi::CString;
use std::io::{self, BufRead, IsTerminal, Write};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

use crate::git::Git;
use crate::paths::display;
use crate::picker;
use crate::procs;
use crate::remove::{self, RemoveError};
use crate::report::{self, Entry, Report};
use crate::style::{self, Paint};
use crate::worktree::{Plan, Worktree};

#[derive(Debug, Default, Clone, Copy)]
pub struct Selectors {
    pub flagged: bool,
    pub stale: bool,
    pub large: bool,
    pub missing: bool,
    pub all: bool,
}

impl Selectors {
    pub fn any(&self) -> bool {
        self.flagged || self.stale || self.large || self.missing || self.all
    }

    fn matches(&self, e: &Entry) -> bool {
        self.all
            || (self.flagged && e.is_flagged())
            || (self.stale && e.is_stale())
            || (self.large && e.is_large())
            || (self.missing && e.worktree.is_prunable)
    }
}

pub struct CleanOptions {
    pub selectors: Selectors,
    pub dry_run: bool,
    pub yes: bool,
    pub force: bool,
    pub measured: bool,
}

/// The exit code: 0 when everything chosen was handled, 1 when something failed or the user
/// must act, 2 for a usage error.
pub fn run(git: &dyn Git, report: Report, options: &CleanOptions, paint: &Paint) -> i32 {
    let interactive = io::stdin().is_terminal() && io::stdout().is_terminal();
    let chosen: Vec<Entry> = if options.selectors.any() {
        report.entries.iter().filter(|e| options.selectors.matches(e)).cloned().collect()
    } else if interactive {
        if report.entries.is_empty() {
            report::print_header(&report, paint, options.measured);
            println!("\n {} No linked worktrees here.\n", paint.green("✓"));
            return 0;
        }
        match picker::pick(report.entries.clone(), &display(&report.root), report.now) {
            Ok(Some(chosen)) => chosen,
            Ok(None) => {
                println!(" Nothing removed.");
                return 0;
            }
            Err(error) => {
                eprintln!("squish: the picker failed: {error}");
                return 1;
            }
        }
    } else {
        eprintln!(
            "squish: choose what to clean with --flagged, --stale, --large, --missing or --all \
             (or run in a terminal to pick interactively)"
        );
        return 2;
    };

    report::print_header(&report, paint, options.measured);
    let plan = Plan::new(chosen.iter().map(|e| e.worktree.clone()), &report.active_paths);
    print_plan(&plan, paint, options.measured);
    if plan.is_empty() {
        println!("\n {} Nothing to remove.\n", paint.green("✓"));
        return 0;
    }

    if options.dry_run {
        let more = plan.bytes(true) - plan.bytes(false);
        let mut line = format!("\n {} nothing was removed.", paint.bold("Dry run:"));
        if options.measured {
            line.push_str(&format!(" Would free {}", paint.green(style::bytes(plan.bytes(false)))));
            if more > 0 {
                line.push_str(&format!(", {} more with the worktrees that have work", style::bytes(more)));
            }
            line.push('.');
        }
        println!("{line}\n");
        return 0;
    }

    let can_ask = interactive && !options.yes;
    let routine = plan.clean.len() + plan.prune.len();
    if routine > 0 && !options.yes {
        if !can_ask {
            println!("\n Run again with {} to remove these.\n", paint.cyan("--yes"));
            return 1;
        }
        let freeing =
            if options.measured { format!(", freeing {}", style::bytes(plan.bytes(false))) } else { String::new() };
        if !ask(&format!("Remove {routine} {}{freeing}?", if routine == 1 { "worktree" } else { "worktrees" }), paint) {
            println!(" Nothing removed.");
            return 0;
        }
    }
    let include_work = !plan.loses_work.is_empty()
        && (options.force
            || (can_ask
                && ask(
                    &format!(
                        "Also remove the {} with work found nowhere else? Uncommitted changes are deleted; \
                         commits stay on their branch (detached ones are saved on a squish/rescued-… branch).",
                        plural(plan.loses_work.len(), "worktree")
                    ),
                    paint,
                )));
    if !plan.loses_work.is_empty() && !include_work {
        let hint = if can_ask { "" } else { " (pass --force to include them)" };
        println!(" Keeping the {} with work{hint}.", plural(plan.loses_work.len(), "worktree"));
    }

    execute(git, &plan, include_work, &report.root, paint, options.measured)
}

fn print_plan(plan: &Plan, paint: &Paint, measured: bool) {
    let size = |w: &Worktree| {
        if measured { w.size_bytes.map(style::bytes).unwrap_or_else(|| "—".into()) } else { String::new() }
    };
    let width = plan
        .clean
        .iter()
        .chain(&plan.loses_work)
        .chain(&plan.prune)
        .chain(plan.skipped.iter().map(|(w, _)| w))
        .map(|w| label(w).chars().count())
        .max()
        .unwrap_or(10)
        .min(60);
    let total = |list: &[Worktree]| -> String {
        let bytes: u64 = list.iter().filter_map(|w| w.size_bytes).sum();
        if measured { format!(" · {}", style::bytes(bytes)) } else { String::new() }
    };

    if !plan.clean.is_empty() {
        println!(
            "\n {} {}{}",
            paint.purple_bold("➤"),
            paint.bold(format!("Remove {}", plural(plan.clean.len(), "clean worktree"))),
            paint.dim(total(&plan.clean))
        );
        for w in &plan.clean {
            println!("   {} {}  {:>8}", paint.green("✓"), style::pad(&label(w), width), size(w));
        }
    }
    if !plan.loses_work.is_empty() {
        println!(
            "\n {} {}{}",
            paint.purple_bold("➤"),
            paint.bold(format!("{} with work found nowhere else", plural(plan.loses_work.len(), "worktree"))),
            paint.dim(total(&plan.loses_work))
        );
        for w in &plan.loses_work {
            let mut lost = Vec::new();
            if w.uncommitted > 0 {
                lost.push(format!("{} uncommitted", w.uncommitted));
            }
            if w.unpushed > 0 {
                lost.push(format!("{} unpushed", w.unpushed));
            }
            if w.branch.is_none() && w.unpushed > 0 {
                lost.push(format!("commits will be saved on {}", remove::rescue_branch_base(&w.head)));
            }
            println!(
                "   {} {}  {:>8}  {}",
                paint.magenta("!"),
                style::pad(&label(w), width),
                size(w),
                paint.magenta(lost.join(" · "))
            );
        }
    }
    if !plan.prune.is_empty() {
        println!(
            "\n {} {}",
            paint.purple_bold("➤"),
            paint.bold(format!("Prune {}", plural(plan.prune.len(), "missing worktree")))
        );
        for w in &plan.prune {
            println!("   {} {}", paint.yellow("○"), style::pad(&label(w), width));
        }
    }
    if !plan.skipped.is_empty() {
        println!(
            "\n {} {}",
            paint.purple_bold("➤"),
            paint.bold(format!("Skip {}", plural(plan.skipped.len(), "worktree")))
        );
        for (w, reason) in &plan.skipped {
            println!("   {} {}  {}", paint.dim("–"), style::pad(&label(w), width), paint.dim(reason));
        }
    }
}

fn execute(git: &dyn Git, plan: &Plan, include_work: bool, root: &Path, paint: &Paint, measured: bool) -> i32 {
    let mut freed = 0u64;
    let (mut removed, mut pruned, mut failed) = (0usize, 0usize, 0usize);
    let mut rescued = Vec::new();
    let forced: &[Worktree] = if include_work { &plan.loses_work } else { &[] };
    let total = plan.clean.len() + forced.len() + plan.prune.len();
    if total == 0 {
        println!(" Nothing removed.\n");
        return 0;
    }
    println!("\n {} {}", paint.purple_bold("➤"), paint.bold(format!("Removing {}", plural(total, "worktree"))));

    let jobs = plan.clean.iter().map(|w| (w, false)).chain(forced.iter().map(|w| (w, true)));
    for (worktree, force) in jobs {
        print!("   {} {}", paint.dim("…"), label(worktree));
        let _ = io::stdout().flush();
        // Probed for each removal: a session may have started since the scan.
        let active = procs::active_paths();
        let result = remove::remove(git, worktree, &active, force, worktree.uncommitted, worktree.unpushed);
        print!("\r\x1b[2K");
        match result {
            Ok(branch) => {
                removed += 1;
                freed += worktree.size_bytes.unwrap_or(0);
                let mut line = format!("   {} {}", paint.green("✓"), label(worktree));
                if measured && let Some(bytes) = worktree.size_bytes {
                    line.push_str(&format!("  {}", paint.dim(style::bytes(bytes))));
                }
                if let Some(branch) = branch {
                    line.push_str(&format!("  commits saved on {}", paint.cyan(&branch)));
                    rescued.push(branch);
                }
                println!("{line}");
            }
            Err(error) => {
                failed += 1;
                let verb = if matches!(error, RemoveError::Refused(_)) { "kept" } else { "failed" };
                println!("   {} {}  {}", paint.red("✗"), label(worktree), paint.red(format!("{verb}: {error}")));
            }
        }
    }

    // One prune per repo clears every missing worktree in it.
    let mut by_repo: BTreeMap<PathBuf, usize> = BTreeMap::new();
    for w in &plan.prune {
        *by_repo.entry(w.repo.clone()).or_default() += 1;
    }
    for (repo, count) in by_repo {
        match git.prune(&repo) {
            Ok(()) => {
                pruned += count;
                println!("   {} pruned {} in {}", paint.green("✓"), plural(count, "missing worktree"), display(&repo));
            }
            Err(error) => {
                failed += count;
                println!("   {} prune in {} failed: {}", paint.red("✗"), display(&repo), paint.red(error));
            }
        }
    }

    let width = style::terminal_width().saturating_sub(2).min(72);
    println!("\n {}", paint.purple_bold("═".repeat(width)));
    let mut summary = Vec::new();
    if measured {
        summary.push(format!("{} {}", paint.bold("Space freed:"), paint.green(style::bytes(freed))));
    }
    summary.push(format!("Removed {removed}"));
    if pruned > 0 {
        summary.push(format!("Pruned {pruned}"));
    }
    if failed > 0 {
        summary.push(paint.red(format!("Failed {failed}")));
    }
    if let Some(free) = free_space(root) {
        summary.push(format!("Free space now: {}", style::bytes(free)));
    }
    println!(" {}", summary.join(&paint.dim(" | ")));
    println!(" {}", paint.purple_bold("═".repeat(width)));
    if !rescued.is_empty() {
        println!(" Detached commits were saved on {}.", rescued.join(", "));
    }
    println!();
    if failed > 0 { 1 } else { 0 }
}

fn label(w: &Worktree) -> String {
    format!("{}  {}", w.repo_name(), w.display_name())
}

fn plural(n: usize, noun: &str) -> String {
    format!("{n} {noun}{}", if n == 1 { "" } else { "s" })
}

/// Asks a yes/no question on the terminal; anything but y or yes is no.
fn ask(question: &str, paint: &Paint) -> bool {
    print!("\n {} {} {} ", paint.yellow("?"), paint.bold(question), paint.dim("[y/N]"));
    let _ = io::stdout().flush();
    let mut answer = String::new();
    if io::stdin().lock().read_line(&mut answer).is_err() {
        return false;
    }
    matches!(answer.trim().to_ascii_lowercase().as_str(), "y" | "yes")
}

/// Bytes available to the user on the volume holding `path`.
fn free_space(path: &Path) -> Option<u64> {
    let path = CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut stats: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `path` is NUL-terminated and `stats` is a valid, writable statvfs.
    if unsafe { libc::statvfs(path.as_ptr(), &mut stats) } != 0 {
        return None;
    }
    // The field types differ between macOS and Linux.
    #[allow(clippy::useless_conversion)]
    Some(u64::from(stats.f_bavail) * u64::from(stats.f_frsize))
}
