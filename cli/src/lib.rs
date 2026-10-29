//! squish: finds the git worktrees your coding agents left behind and cleans them up safely.

pub mod clean;
pub mod discovery;
pub mod git;
pub mod paths;
pub mod picker;
pub mod porcelain;
pub mod procs;
pub mod remove;
pub mod report;
pub mod scan;
pub mod size;
pub mod style;
pub mod worktree;
