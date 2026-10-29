//! Runs the squish binary against real git repos in a temporary folder.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, SystemTime};

use serde_json::Value;

fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        // An old commit, so only the index decides whether a worktree is stale.
        .env("GIT_AUTHOR_DATE", "2020-01-01T00:00:00")
        .env("GIT_COMMITTER_DATE", "2020-01-01T00:00:00")
        .args(["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "init.defaultBranch=main"])
        .args(args)
        .current_dir(dir)
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .output()
        .expect("git runs");
    assert!(output.status.success(), "git {args:?} failed: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn squish(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_squish"))
        .args(args)
        .args(["--color", "never"])
        .stdin(Stdio::null())
        .output()
        .expect("squish runs")
}

/// Makes the worktree look untouched for `days` (its commits are already old).
fn age(worktree: &Path, days: u64) {
    let then = SystemTime::now() - Duration::from_secs(days * 86_400);
    let git_dir = git(worktree, &["rev-parse", "--path-format=absolute", "--git-dir"]);
    let index = PathBuf::from(git_dir.trim()).join("index");
    fs::File::options().write(true).open(index).unwrap().set_modified(then).unwrap();
}

struct Fixture {
    _dir: tempfile::TempDir,
    root: PathBuf,
    repo: PathBuf,
}

impl Fixture {
    /// A repo with one commit, pushed nowhere, and linked worktrees:
    /// clean (stale), dirty, detached with a unique commit, locked, and missing.
    fn new() -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let root = fs::canonicalize(dir.path()).unwrap();
        let repo = root.join("projects/app");
        fs::create_dir_all(&repo).unwrap();
        git(&repo, &["init", "-q"]);
        fs::write(repo.join("README"), "hello").unwrap();
        git(&repo, &["add", "."]);
        git(&repo, &["commit", "-q", "-m", "first"]);

        git(&repo, &["worktree", "add", "-q", "-b", "clean", "../wt-clean"]);
        git(&repo, &["worktree", "add", "-q", "-b", "dirty", "../wt-dirty"]);
        fs::write(root.join("projects/wt-dirty/new.txt"), "work").unwrap();
        git(&repo, &["worktree", "add", "-q", "--detach", "../wt-detached"]);
        fs::write(root.join("projects/wt-detached/x"), "x").unwrap();
        git(&root.join("projects/wt-detached"), &["add", "x"]);
        git(&root.join("projects/wt-detached"), &["commit", "-q", "-m", "only here"]);
        git(&repo, &["worktree", "add", "-q", "-b", "locked", "../wt-locked"]);
        git(&repo, &["worktree", "lock", "../wt-locked"]);
        git(&repo, &["worktree", "add", "-q", "-b", "gone", "../wt-gone"]);
        fs::remove_dir_all(root.join("projects/wt-gone")).unwrap();
        age(&root.join("projects/wt-clean"), 30);
        Fixture { _dir: dir, root, repo }
    }

    fn analyze(&self) -> Value {
        let output = squish(&["analyze", "--json", self.root.to_str().unwrap()]);
        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        serde_json::from_slice(&output.stdout).unwrap()
    }

    fn worktree_paths(&self) -> Vec<String> {
        git(&self.repo, &["worktree", "list", "--porcelain"])
            .lines()
            .filter_map(|l| l.strip_prefix("worktree "))
            .map(|p| Path::new(p).file_name().unwrap().to_string_lossy().into_owned())
            .collect()
    }
}

fn by_name<'a>(report: &'a Value, name: &str) -> &'a Value {
    report["worktrees"]
        .as_array()
        .unwrap()
        .iter()
        .find(|w| w["path"].as_str().unwrap().ends_with(name))
        .unwrap_or_else(|| panic!("{name} is listed"))
}

#[test]
fn analyze_reports_every_linked_worktree() {
    let fixture = Fixture::new();
    let report = fixture.analyze();
    assert_eq!(report["repos"].as_array().unwrap().len(), 1);
    assert_eq!(report["worktrees"].as_array().unwrap().len(), 5);

    let clean = by_name(&report, "wt-clean");
    assert_eq!(clean["removal"], "clean");
    assert_eq!(clean["stale"], true);
    assert_eq!(clean["branch"], "clean");
    assert!(clean["size_bytes"].as_u64().unwrap() > 0);

    let dirty = by_name(&report, "wt-dirty");
    assert_eq!(dirty["removal"], "loses_work");
    assert_eq!(dirty["uncommitted"], 1);
    assert_eq!(dirty["stale"], false);

    let detached = by_name(&report, "wt-detached");
    assert_eq!(detached["removal"], "loses_work");
    assert_eq!(detached["unpushed"], 1);
    assert_eq!(detached["branch"], Value::Null);

    assert_eq!(by_name(&report, "wt-locked")["removal"], "blocked");
    assert_eq!(by_name(&report, "wt-gone")["removal"], "prune");
}

#[test]
fn analyze_finds_the_repo_from_inside_a_worktree() {
    let fixture = Fixture::new();
    let output =
        squish(&["analyze", "--json", "--depth", "0", fixture.root.join("projects/wt-dirty").to_str().unwrap()]);
    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["worktrees"].as_array().unwrap().len(), 5);
}

#[test]
fn analyze_prints_a_readable_summary() {
    let fixture = Fixture::new();
    let output = squish(&["analyze", fixture.root.to_str().unwrap()]);
    let text = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success());
    assert!(text.contains("1 repo · 5 linked worktrees"), "{text}");
    assert!(text.contains("1 uncommitted"), "{text}");
    assert!(text.contains("directory missing"), "{text}");
    assert!(text.contains("squish clean --flagged"), "{text}");
}

#[test]
fn clean_without_a_choice_off_a_terminal_is_a_usage_error() {
    let fixture = Fixture::new();
    let output = squish(&["clean", fixture.root.to_str().unwrap()]);
    assert_eq!(output.status.code(), Some(2));
    assert_eq!(fixture.worktree_paths().len(), 6);
}

#[test]
fn clean_asks_for_yes_off_a_terminal_and_dry_run_removes_nothing() {
    let fixture = Fixture::new();
    let root = fixture.root.to_str().unwrap();
    let output = squish(&["clean", "--all", root]);
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stdout).contains("--yes"));

    let output = squish(&["clean", "--all", "--dry-run", "--yes", "--force", root]);
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("Dry run"));
    assert_eq!(fixture.worktree_paths().len(), 6);
}

#[test]
fn clean_stale_removes_only_the_stale_worktree_and_keeps_its_branch() {
    let fixture = Fixture::new();
    let output = squish(&["clean", "--stale", "--yes", fixture.root.to_str().unwrap()]);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stdout));
    let left = fixture.worktree_paths();
    assert!(!left.contains(&"wt-clean".to_string()));
    assert_eq!(left.len(), 5);
    assert!(!fixture.root.join("projects/wt-clean").exists());
    assert!(git(&fixture.repo, &["branch", "--list", "clean"]).contains("clean"));
}

#[test]
fn clean_all_keeps_work_without_force() {
    let fixture = Fixture::new();
    let output = squish(&["clean", "--all", "--yes", fixture.root.to_str().unwrap()]);
    let text = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "{text}");
    assert!(text.contains("Keeping the 2 worktrees with work"), "{text}");
    let mut left = fixture.worktree_paths();
    left.sort();
    assert_eq!(left, ["app", "wt-detached", "wt-dirty", "wt-locked"]);
}

#[test]
fn clean_all_with_force_rescues_detached_commits() {
    let fixture = Fixture::new();
    let detached_head = git(&fixture.root.join("projects/wt-detached"), &["rev-parse", "HEAD"]);
    let output = squish(&["clean", "--all", "--yes", "--force", fixture.root.to_str().unwrap()]);
    let text = String::from_utf8_lossy(&output.stdout);
    assert!(output.status.success(), "{text}");
    let mut left = fixture.worktree_paths();
    left.sort();
    assert_eq!(left, ["app", "wt-locked"]);
    let rescued = format!("squish/rescued-{}", &detached_head[..7]);
    assert!(text.contains(&rescued), "{text}");
    assert_eq!(git(&fixture.repo, &["rev-parse", &rescued]), detached_head);
}

#[test]
fn clean_skips_a_worktree_a_process_is_working_in() {
    let fixture = Fixture::new();
    let worktree = fixture.root.join("projects/wt-clean");
    let mut sleeper = Command::new("sleep").arg("30").current_dir(&worktree).spawn().unwrap();
    let output = squish(&["clean", "--all", "--yes", fixture.root.to_str().unwrap()]);
    sleeper.kill().unwrap();
    let _ = sleeper.wait();
    let text = String::from_utf8_lossy(&output.stdout);
    assert!(text.contains("a process is working in this worktree"), "{text}");
    assert!(worktree.exists());
}
