//! The git operations worktree analysis and cleanup need, behind a trait so tests can fake them.

use std::fmt;
use std::io::Read;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::paths::normalized;
use crate::porcelain::{self, WorktreeRecord};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GitError {
    /// No usable git: the binary is missing, or the macOS command line tools are not installed.
    Unavailable,
    TimedOut(String),
    Failed(String),
}

impl fmt::Display for GitError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            GitError::Unavailable => {
                write!(f, "git is not available. Install it (on macOS: xcode-select --install).")
            }
            GitError::TimedOut(command) => write!(f, "git {command} took too long and was stopped."),
            GitError::Failed(message) => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for GitError {}

pub trait Git: Sync {
    fn list_worktrees(&self, repo: &Path) -> Result<Vec<WorktreeRecord>, GitError>;
    /// Entries in `git status --porcelain`, untracked included, ignored excluded.
    fn uncommitted_count(&self, worktree: &Path) -> Result<usize, GitError>;
    /// Commits reachable from HEAD that are on no remote and no other local branch.
    fn unpushed_count(&self, worktree: &Path, branch: Option<&str>) -> Result<usize, GitError>;
    /// The later of the HEAD commit date and the last change to the worktree's index.
    fn last_activity(&self, worktree: &Path) -> Result<Option<SystemTime>, GitError>;
    /// The main worktree of the repo containing `path`; None outside a repo (or in a bare one).
    fn main_repo_root(&self, path: &Path) -> Result<Option<PathBuf>, GitError>;
    fn remove(&self, worktree: &Path, repo: &Path, force: bool) -> Result<(), GitError>;
    fn prune(&self, repo: &Path) -> Result<(), GitError>;
    /// Creates branch `name` at commit `sha`; fails if the name is taken.
    fn create_branch(&self, name: &str, sha: &str, repo: &Path) -> Result<(), GitError>;
}

/// Runs the `git` on PATH.
pub struct ProcessGit {
    pub program: PathBuf,
    /// For reads. Destructive commands run without one: killing one midway could leave a
    /// half-deleted worktree.
    pub timeout: Duration,
}

impl Default for ProcessGit {
    fn default() -> Self {
        ProcessGit { program: PathBuf::from("git"), timeout: Duration::from_secs(15) }
    }
}

/// Variables that would point git at another repo, index or object store than the directory it
/// runs in (set when squish runs from a git hook or a git-aware shell).
const REPO_OVERRIDE_VARIABLES: &[&str] = &[
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_COMMON_DIR",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_NAMESPACE",
];

impl ProcessGit {
    fn read(&self, args: &[&str], dir: &Path) -> Result<String, GitError> {
        self.run(args, dir, Some(self.timeout))
    }

    /// Runs git in `dir` and returns stdout; `timeout: None` waits for as long as git takes.
    pub fn run(&self, args: &[&str], dir: &Path, timeout: Option<Duration>) -> Result<String, GitError> {
        if !dir.is_dir() {
            return Err(GitError::Failed(format!("No such directory: {}", dir.display())));
        }
        let mut command = Command::new(&self.program);
        command
            .args(args)
            .current_dir(dir)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("GIT_OPTIONAL_LOCKS", "0")
            .env("LC_ALL", "C");
        for name in REPO_OVERRIDE_VARIABLES {
            command.env_remove(name);
        }
        if timeout.is_none() {
            // A destructive command gets its own process group, so a Ctrl-C meant for squish
            // cannot stop it halfway through deleting a worktree.
            command.process_group(0);
        }
        let mut child = command.spawn().map_err(|_| GitError::Unavailable)?;

        // Both pipes drain on their own threads so large output cannot fill one and stall git.
        // The readers report over a channel, so a grandchild holding a pipe open cannot hang us.
        let (sender, receiver) = mpsc::channel::<(bool, Vec<u8>)>();
        for (is_stdout, pipe) in [
            (true, child.stdout.take().map(|p| Box::new(p) as Box<dyn Read + Send>)),
            (false, child.stderr.take().map(|p| Box::new(p) as Box<dyn Read + Send>)),
        ] {
            let sender = sender.clone();
            if let Some(mut pipe) = pipe {
                thread::spawn(move || {
                    let mut data = Vec::new();
                    let _ = pipe.read_to_end(&mut data);
                    let _ = sender.send((is_stdout, data));
                });
            }
        }
        drop(sender);

        let deadline = timeout.map(|t| Instant::now() + t);
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break status,
                Ok(None) => {}
                Err(error) => return Err(GitError::Failed(error.to_string())),
            }
            if deadline.is_some_and(|d| Instant::now() >= d) {
                let _ = child.kill();
                let _ = child.wait();
                return Err(GitError::TimedOut(args.first().unwrap_or(&"").to_string()));
            }
            thread::sleep(Duration::from_millis(5));
        };

        let (mut stdout, mut stderr) = (Vec::new(), Vec::new());
        let drain_deadline = Instant::now() + Duration::from_secs(2);
        for _ in 0..2 {
            let left = drain_deadline.saturating_duration_since(Instant::now());
            match receiver.recv_timeout(left) {
                Ok((true, data)) => stdout = data,
                Ok((false, data)) => stderr = data,
                Err(_) => break,
            }
        }

        let error_text = String::from_utf8_lossy(&stderr);
        if !status.success() {
            // /usr/bin/git is a shim that fails this way when the command line tools are missing.
            if error_text.contains("xcrun: error") {
                return Err(GitError::Unavailable);
            }
            let message = error_text.trim();
            return Err(GitError::Failed(if message.is_empty() {
                format!("git {} failed", args.first().unwrap_or(&""))
            } else {
                message.to_string()
            }));
        }
        Ok(String::from_utf8_lossy(&stdout).into_owned())
    }
}

impl Git for ProcessGit {
    fn list_worktrees(&self, repo: &Path) -> Result<Vec<WorktreeRecord>, GitError> {
        Ok(porcelain::worktrees(&self.read(&["worktree", "list", "--porcelain"], repo)?))
    }

    fn uncommitted_count(&self, worktree: &Path) -> Result<usize, GitError> {
        // Explicit --untracked-files so status.showUntrackedFiles=no cannot hide untracked work.
        let output = self.read(&["status", "--porcelain", "--untracked-files=normal"], worktree)?;
        Ok(porcelain::status_entry_count(&output))
    }

    fn unpushed_count(&self, worktree: &Path, branch: Option<&str>) -> Result<usize, GitError> {
        let exclude = branch.map(|b| format!("--exclude={b}"));
        let mut args = vec!["rev-list", "--count", "HEAD", "--not"];
        // --exclude patterns for --branches are relative to refs/heads/.
        if let Some(exclude) = &exclude {
            args.push(exclude);
        }
        args.extend(["--branches", "--remotes"]);
        let output = self.read(&args, worktree)?;
        // Never read garbage as "nothing unpushed": that would let work be deleted unconfirmed.
        output
            .trim()
            .parse()
            .map_err(|_| GitError::Failed(format!("git rev-list printed an unexpected count: {}", output.trim())))
    }

    fn last_activity(&self, worktree: &Path) -> Result<Option<SystemTime>, GitError> {
        let commit = self.read(&["log", "-1", "--format=%ct", "HEAD"], worktree)?;
        let commit_date = commit.trim().parse::<u64>().ok().map(|s| UNIX_EPOCH + Duration::from_secs(s));
        let git_dir = self.read(&["rev-parse", "--path-format=absolute", "--git-dir"], worktree)?;
        let index_date = std::fs::metadata(Path::new(git_dir.trim()).join("index")).and_then(|m| m.modified()).ok();
        Ok(commit_date.into_iter().chain(index_date).max())
    }

    fn main_repo_root(&self, path: &Path) -> Result<Option<PathBuf>, GitError> {
        let output = match self.read(&["rev-parse", "--path-format=absolute", "--git-common-dir"], path) {
            Ok(output) => output,
            Err(GitError::Failed(_)) => return Ok(None),
            Err(error) => return Err(error),
        };
        let common_dir = PathBuf::from(output.trim());
        if common_dir.file_name().is_none_or(|name| name != ".git") {
            return Ok(None);
        }
        Ok(common_dir.parent().map(normalized))
    }

    fn remove(&self, worktree: &Path, repo: &Path, force: bool) -> Result<(), GitError> {
        let path = worktree.to_string_lossy();
        let mut args = vec!["worktree", "remove"];
        if force {
            args.push("--force");
        }
        args.push(&path);
        self.run(&args, repo, None).map(|_| ())
    }

    fn prune(&self, repo: &Path) -> Result<(), GitError> {
        self.run(&["worktree", "prune"], repo, None).map(|_| ())
    }

    fn create_branch(&self, name: &str, sha: &str, repo: &Path) -> Result<(), GitError> {
        self.read(&["branch", name, sha], repo).map(|_| ())
    }
}
