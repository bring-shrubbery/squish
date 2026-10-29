use std::path::{Path, PathBuf};

/// Symlinks resolved, so `/var/…` and `/private/var/…` compare equal. A path that no longer
/// exists resolves its nearest existing ancestor.
pub fn normalized(path: &Path) -> PathBuf {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().map(|cwd| cwd.join(path)).unwrap_or_else(|_| path.to_path_buf())
    };
    if let Ok(resolved) = std::fs::canonicalize(&absolute) {
        return resolved;
    }
    match (absolute.parent(), absolute.file_name()) {
        (Some(parent), Some(name)) => normalized(parent).join(name),
        _ => absolute,
    }
}

/// The path with the home directory shortened to `~`.
pub fn display(path: &Path) -> String {
    if let Some(home) = std::env::var_os("HOME").map(PathBuf::from)
        && let Ok(rest) = path.strip_prefix(&home)
    {
        return if rest.as_os_str().is_empty() { "~".into() } else { format!("~/{}", rest.display()) };
    }
    path.display().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_symlinks_and_missing_leaves() {
        let dir = tempfile::tempdir().unwrap();
        let real = normalized(dir.path());
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        assert_eq!(normalized(&link), real);
        assert_eq!(normalized(&link.join("gone/deeper")), real.join("gone/deeper"));
    }
}
