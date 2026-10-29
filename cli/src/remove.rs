//! Removes a worktree only after re-reading its state from git, never from an earlier scan.

use std::path::{Path, PathBuf};

use crate::git::{Git, GitError};
use crate::paths::normalized;
use crate::worktree::{self, LOCKED_REASON, Worktree};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemoveError {
    /// Refused before anything was deleted.
    Refused(String),
    Git(GitError),
}

impl std::fmt::Display for RemoveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RemoveError::Refused(reason) => write!(f, "{reason}"),
            RemoveError::Git(error) => write!(f, "{error}"),
        }
    }
}

impl From<GitError> for RemoveError {
    fn from(error: GitError) -> Self {
        RemoveError::Git(error)
    }
}

pub fn rescue_branch_base(head: &str) -> String {
    format!("squish/rescued-{}", &head[..head.len().min(7)])
}

/// Re-reads the worktree from git and removes it if `worktree::fresh_removal_check` allows.
/// A forced removal of a detached HEAD with unique commits first saves them on a new branch
/// (`squish/rescued-<short sha>`, suffixed `-2`, `-3`… when taken), since `git worktree remove`
/// deletes the worktree's HEAD reflog. Returns that branch's name, if one was made.
/// `active_paths` are the processes' cwds, probed just before.
pub fn remove(
    git: &dyn Git,
    worktree: &Worktree,
    active_paths: &[PathBuf],
    force: bool,
    confirmed_uncommitted: usize,
    confirmed_unpushed: usize,
) -> Result<Option<String>, RemoveError> {
    let path = normalized(&worktree.path);
    let record = git
        .list_worktrees(&worktree.repo)?
        .into_iter()
        .find(|r| !r.is_main && normalized(Path::new(&r.path)) == path)
        .ok_or_else(|| RemoveError::Refused("it is no longer listed by git".into()))?;
    if record.is_prunable {
        return Err(RemoveError::Refused("its directory is gone; it will be pruned instead".into()));
    }
    if record.is_locked {
        return Err(RemoveError::Refused(LOCKED_REASON.into()));
    }
    if record.branch != worktree.branch {
        return Err(RemoveError::Refused("it changed branch since the scan; run clean again".into()));
    }
    let uncommitted = git.uncommitted_count(&path)?;
    let unpushed = git.unpushed_count(&path, record.branch.as_deref())?;
    let active = worktree::is_active(&path, active_paths);
    if let Some(reason) =
        worktree::fresh_removal_check(uncommitted, unpushed, active, force, confirmed_uncommitted, confirmed_unpushed)
    {
        return Err(RemoveError::Refused(reason));
    }
    let rescued = if force && record.branch.is_none() && unpushed > 0 {
        Some(rescue(git, &record.head, &worktree.repo)?)
    } else {
        None
    };
    git.remove(&path, &worktree.repo, force)?;
    Ok(rescued)
}

fn rescue(git: &dyn Git, head: &str, repo: &Path) -> Result<String, RemoveError> {
    let base = rescue_branch_base(head);
    for attempt in 1..=100 {
        let name = if attempt == 1 { base.clone() } else { format!("{base}-{attempt}") };
        match git.create_branch(&name, head, repo) {
            Ok(()) => return Ok(name),
            Err(GitError::Failed(message)) if message.contains("already exists") => continue,
            Err(error) => {
                return Err(RemoveError::Refused(format!(
                    "couldn't save its detached commits on a branch, so nothing was removed: {error}"
                )));
            }
        }
    }
    Err(RemoveError::Refused("couldn't find a free squish/rescued-… branch name, so nothing was removed".into()))
}
