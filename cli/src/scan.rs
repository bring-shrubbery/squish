//! Finds repos under a folder and reads their linked worktrees.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;

use crate::discovery;
use crate::git::{Git, GitError};
use crate::paths::normalized;
use crate::porcelain::WorktreeRecord;
use crate::worktree::Worktree;

/// The linked worktrees of one repo, or why they could not be listed.
#[derive(Debug, Clone)]
pub struct RepoScan {
    pub repo: PathBuf,
    pub worktrees: Vec<Worktree>,
    pub error: Option<String>,
}

/// Main repo roots for every candidate under `root`, deduplicated and sorted.
/// Fails only with `GitError::Unavailable`; any other failure skips that candidate.
pub fn repos(git: &dyn Git, root: &Path, max_depth: usize) -> Result<Vec<PathBuf>, GitError> {
    let candidates = discovery::candidates(root, max_depth);
    let roots = par_map(&candidates, |candidate| git.main_repo_root(candidate));
    let mut found = BTreeSet::new();
    for root in roots {
        match root {
            Ok(Some(root)) => {
                found.insert(root);
            }
            Ok(None) | Err(GitError::Failed(_) | GitError::TimedOut(_)) => {}
            Err(GitError::Unavailable) => return Err(GitError::Unavailable),
        }
    }
    Ok(found.into_iter().collect())
}

/// Lists every repo's linked worktrees and reads each one's details, all in parallel.
/// `progress` gets (worktrees read, worktrees found).
pub fn scan(git: &dyn Git, repos: &[PathBuf], progress: &(dyn Fn(usize, usize) + Sync)) -> Vec<RepoScan> {
    let listed = par_map(repos, |repo| git.list_worktrees(repo));
    let mut jobs: Vec<(PathBuf, WorktreeRecord)> = Vec::new();
    let mut scans: Vec<RepoScan> = Vec::new();
    for (repo, records) in repos.iter().zip(listed) {
        let repo = normalized(repo);
        match records {
            Ok(records) => {
                jobs.extend(records.into_iter().filter(|r| !r.is_main && !r.is_bare).map(|r| (repo.clone(), r)));
                scans.push(RepoScan { repo, worktrees: Vec::new(), error: None });
            }
            Err(error) => scans.push(RepoScan { repo, worktrees: Vec::new(), error: Some(error.to_string()) }),
        }
    }
    let done = AtomicUsize::new(0);
    let worktrees = par_map(&jobs, |(repo, record)| {
        let worktree = read_worktree(git, repo, record);
        progress(done.fetch_add(1, Ordering::Relaxed) + 1, jobs.len());
        worktree
    });
    for worktree in worktrees {
        if let Some(scan) = scans.iter_mut().find(|s| s.repo == worktree.repo) {
            scan.worktrees.push(worktree);
        }
    }
    scans
}

/// A failure reading one worktree marks it with `detail_error` instead of failing the scan.
fn read_worktree(git: &dyn Git, repo: &Path, record: &WorktreeRecord) -> Worktree {
    let path = normalized(Path::new(&record.path));
    let mut worktree = Worktree {
        path,
        repo: repo.to_path_buf(),
        branch: record.branch.clone(),
        head: record.head.clone(),
        is_locked: record.is_locked,
        is_prunable: record.is_prunable,
        last_activity: None,
        uncommitted: 0,
        unpushed: 0,
        size_bytes: None,
        detail_error: None,
    };
    if record.is_prunable {
        return worktree;
    }
    let details = (|| {
        Ok::<_, GitError>((
            git.last_activity(&worktree.path)?,
            git.uncommitted_count(&worktree.path)?,
            git.unpushed_count(&worktree.path, record.branch.as_deref())?,
        ))
    })();
    match details {
        Ok((last_activity, uncommitted, unpushed)) => {
            worktree.last_activity = last_activity;
            worktree.uncommitted = uncommitted;
            worktree.unpushed = unpushed;
        }
        Err(error) => worktree.detail_error = Some(error.to_string()),
    }
    worktree
}

/// `f` over `items` on a few threads, keeping the order.
pub fn par_map<T: Sync, R: Send>(items: &[T], f: impl Fn(&T) -> R + Sync) -> Vec<R> {
    let next = AtomicUsize::new(0);
    let results: Mutex<Vec<Option<R>>> = Mutex::new((0..items.len()).map(|_| None).collect());
    let workers = thread::available_parallelism().map_or(4, |n| n.get()).clamp(1, 8).min(items.len().max(1));
    thread::scope(|scope| {
        for _ in 0..workers {
            scope.spawn(|| {
                loop {
                    let index = next.fetch_add(1, Ordering::Relaxed);
                    let Some(item) = items.get(index) else { return };
                    let result = f(item);
                    results.lock().unwrap()[index] = Some(result);
                }
            });
        }
    });
    results.into_inner().unwrap().into_iter().map(|r| r.expect("every item is mapped")).collect()
}
