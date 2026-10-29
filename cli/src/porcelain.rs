//! Parsing git's machine-readable output.

/// One record of `git worktree list --porcelain`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorktreeRecord {
    pub path: String,
    pub head: String,
    /// The short branch name; None for a detached HEAD or a bare repo.
    pub branch: Option<String>,
    /// git lists the main worktree first.
    pub is_main: bool,
    pub is_bare: bool,
    pub is_locked: bool,
    pub is_prunable: bool,
}

/// Records are separated by blank lines; each starts with `worktree <path>`.
pub fn worktrees(output: &str) -> Vec<WorktreeRecord> {
    let mut records: Vec<WorktreeRecord> = Vec::new();
    for block in output.split("\n\n") {
        let mut lines = block.lines().filter(|line| !line.is_empty());
        let Some(path) = lines.next().and_then(|first| first.strip_prefix("worktree ")) else {
            continue;
        };
        let mut record = WorktreeRecord {
            path: path.to_string(),
            head: String::new(),
            branch: None,
            is_main: records.is_empty(),
            is_bare: false,
            is_locked: false,
            is_prunable: false,
        };
        for field in lines {
            if let Some(head) = field.strip_prefix("HEAD ") {
                record.head = head.to_string();
            } else if let Some(reference) = field.strip_prefix("branch ") {
                record.branch = Some(reference.strip_prefix("refs/heads/").unwrap_or(reference).to_string());
            } else if field == "bare" {
                record.is_bare = true;
            } else if field == "locked" || field.starts_with("locked ") {
                record.is_locked = true;
            } else if field == "prunable" || field.starts_with("prunable ") {
                record.is_prunable = true;
            }
        }
        records.push(record);
    }
    records
}

/// One entry per non-blank line of `git status --porcelain` (v1; a rename is one line).
pub fn status_entry_count(output: &str) -> usize {
    output.lines().filter(|line| !line.trim().is_empty()).count()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_main_linked_detached_locked_and_prunable_records() {
        let output = "worktree /repo\nHEAD aaa\nbranch refs/heads/main\n\n\
                      worktree /repo/.claude/worktrees/x\nHEAD bbb\nbranch refs/heads/feat/x\nlocked busy\n\n\
                      worktree /tmp/gone\nHEAD ccc\ndetached\nprunable gitdir file points to non-existent location\n\n";
        let records = worktrees(output);
        assert_eq!(records.len(), 3);
        assert!(records[0].is_main);
        assert_eq!(records[0].branch.as_deref(), Some("main"));
        assert!(!records[1].is_main);
        assert_eq!(records[1].branch.as_deref(), Some("feat/x"));
        assert!(records[1].is_locked);
        assert_eq!(records[2].branch, None);
        assert_eq!(records[2].head, "ccc");
        assert!(records[2].is_prunable);
    }

    #[test]
    fn parses_a_bare_main_repo() {
        let records = worktrees("worktree /repo.git\nbare\n\nworktree /wt\nHEAD a\nbranch refs/heads/b\n");
        assert!(records[0].is_bare && records[0].is_main);
        assert!(!records[1].is_main);
    }

    #[test]
    fn counts_status_entries() {
        assert_eq!(status_entry_count(""), 0);
        assert_eq!(status_entry_count(" M a\n?? b\nR  c -> d\n\n"), 3);
    }
}
