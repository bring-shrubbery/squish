//! Finds directories under a folder that may be git repos or linked worktrees. The scanner
//! resolves each candidate to its main repo, so duplicates are harmless.

use std::collections::VecDeque;
use std::path::{Path, PathBuf};

pub const SKIPPED_NAMES: &[&str] = &[
    "node_modules",
    ".build",
    "DerivedData",
    "Pods",
    "vendor",
    "dist",
    "build",
    ".venv",
    "target",
    // ~/Library and friends: slow to walk and full of privacy-protected folders that prompt.
    "Library",
];

/// Directory bundles macOS shows as single documents; never repos to scan.
const PACKAGE_EXTENSIONS: &[&str] = &["app", "bundle", "framework", "photoslibrary", "musiclibrary", "tvlibrary"];

/// `root` itself (it may sit inside a repo) and every directory holding a `.git` within
/// `max_depth` levels below it. Hidden directories are skipped, except `.claude`, where
/// Claude Code keeps its worktrees.
pub fn candidates(root: &Path, max_depth: usize) -> Vec<PathBuf> {
    let mut found = vec![root.to_path_buf()];
    let mut queue = VecDeque::from([(root.to_path_buf(), 0usize)]);
    while let Some((directory, depth)) = queue.pop_front() {
        if depth > 0 && directory.join(".git").exists() {
            found.push(directory.clone());
        }
        if depth >= max_depth {
            continue;
        }
        let Ok(entries) = std::fs::read_dir(&directory) else { continue };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if SKIPPED_NAMES.contains(&name.as_ref()) || (name.starts_with('.') && name != ".claude") {
                continue;
            }
            if Path::new(name.as_ref())
                .extension()
                .is_some_and(|ext| PACKAGE_EXTENSIONS.contains(&ext.to_string_lossy().as_ref()))
            {
                continue;
            }
            // file_type() does not follow symlinks, so linked directories are skipped.
            if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
                queue.push_back((entry.path(), depth + 1));
            }
        }
    }
    found.sort();
    found.dedup();
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn finds_repos_within_depth_and_skips_noise() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        for path in [
            "a/.git",
            "b/c/.git",
            "d/e/f/g/h/.git",
            "node_modules/x/.git",
            ".hidden/y/.git",
            "Foo.app/z/.git",
            "repo/.claude/worktrees/w/.git",
        ] {
            fs::create_dir_all(root.join(path)).unwrap();
        }
        std::os::unix::fs::symlink(root.join("a"), root.join("link")).unwrap();
        let found: Vec<String> =
            candidates(root, 4).iter().map(|p| p.strip_prefix(root).unwrap().display().to_string()).collect();
        assert_eq!(found, ["", "a", "b/c", "repo/.claude/worktrees/w"]);
    }
}
