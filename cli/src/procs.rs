//! The working directories of running processes, so a worktree a shell, editor or agent is
//! working in is never flagged or removed.

use std::path::PathBuf;

use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};

use crate::paths::normalized;

/// Normalized cwds of every process the user can inspect, except squish and the git commands
/// it runs. Processes that cannot be read (other users', exited meanwhile) are skipped.
pub fn active_paths() -> Vec<PathBuf> {
    let Ok(mut system) = System::new() else { return Vec::new() };
    system.refresh_processes_specifics(
        ProcessesToUpdate::All,
        true,
        ProcessRefreshKind::nothing().with_cwd(UpdateKind::Always),
    );
    let own = Pid::from_u32(std::process::id());
    let mut paths: Vec<PathBuf> = system
        .processes()
        .iter()
        .filter(|(pid, process)| **pid != own && process.parent() != Some(own))
        .filter_map(|(_, process)| process.cwd())
        .filter(|cwd| !cwd.as_os_str().is_empty() && cwd.as_os_str() != "/")
        .map(normalized)
        .collect();
    paths.sort();
    paths.dedup();
    paths
}
