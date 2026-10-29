//! Measures how much disk directory trees take: allocated blocks, as `du` counts them, with
//! hard-linked files counted once. All trees share one pool of threads, so one huge worktree
//! does not leave the others' threads idle.

use std::collections::HashSet;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Condvar, Mutex};
use std::thread;

struct Queue {
    jobs: Vec<(usize, PathBuf)>,
    busy: usize,
}

/// The size of each of `roots`; None for one that is not a directory. `progress` is called
/// from the worker threads with the bytes counted so far across all roots.
pub fn measure_all(roots: &[PathBuf], progress: &(dyn Fn(u64) + Sync)) -> Vec<Option<u64>> {
    let totals: Vec<AtomicU64> = roots.iter().map(|_| AtomicU64::new(0)).collect();
    let exists: Vec<bool> = roots.iter().map(|root| root.is_dir()).collect();
    let queue = Mutex::new(Queue {
        jobs: roots.iter().enumerate().filter(|(i, _)| exists[*i]).map(|(i, r)| (i, r.clone())).collect(),
        busy: 0,
    });
    let wake = Condvar::new();
    let hard_links = Mutex::new(HashSet::<(u64, u64)>::new());
    let counted = AtomicU64::new(0);
    let workers = thread::available_parallelism().map_or(4, |n| n.get()).clamp(2, 16);

    thread::scope(|scope| {
        for _ in 0..workers {
            scope.spawn(|| {
                loop {
                    let job = {
                        let mut state = queue.lock().unwrap();
                        loop {
                            if let Some(job) = state.jobs.pop() {
                                state.busy += 1;
                                break Some(job);
                            }
                            if state.busy == 0 {
                                break None;
                            }
                            state = wake.wait(state).unwrap();
                        }
                    };
                    let Some((index, directory)) = job else {
                        wake.notify_all();
                        return;
                    };
                    let (bytes, subdirectories) = read_directory(&directory, &hard_links);
                    totals[index].fetch_add(bytes, Ordering::Relaxed);
                    progress(counted.fetch_add(bytes, Ordering::Relaxed) + bytes);
                    let mut state = queue.lock().unwrap();
                    state.jobs.extend(subdirectories.into_iter().map(|d| (index, d)));
                    state.busy -= 1;
                    drop(state);
                    wake.notify_all();
                }
            });
        }
    });

    totals.iter().zip(exists).map(|(total, exists)| exists.then(|| total.load(Ordering::Relaxed))).collect()
}

/// The bytes of the directory and the files directly in it, and its subdirectories.
/// Symlinks are counted as themselves, never followed.
fn read_directory(directory: &Path, hard_links: &Mutex<HashSet<(u64, u64)>>) -> (u64, Vec<PathBuf>) {
    let mut bytes = std::fs::symlink_metadata(directory).map_or(0, |m| m.blocks() * 512);
    let mut subdirectories = Vec::new();
    let Ok(entries) = std::fs::read_dir(directory) else { return (bytes, subdirectories) };
    for entry in entries.flatten() {
        // DirEntry::metadata does not follow symlinks.
        let Ok(metadata) = entry.metadata() else { continue };
        if metadata.is_dir() {
            subdirectories.push(entry.path());
            continue;
        }
        if metadata.nlink() > 1 && !hard_links.lock().unwrap().insert((metadata.dev(), metadata.ino())) {
            continue;
        }
        bytes += metadata.blocks() * 512;
    }
    (bytes, subdirectories)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn measures_trees_counting_hard_links_once() {
        let dir = tempfile::tempdir().unwrap();
        let a = dir.path().join("a");
        fs::create_dir_all(a.join("deep/er")).unwrap();
        fs::write(a.join("deep/er/file"), vec![1u8; 100_000]).unwrap();
        let b = dir.path().join("b");
        fs::create_dir(&b).unwrap();
        fs::write(b.join("one"), vec![1u8; 50_000]).unwrap();
        let alone = measure_all(std::slice::from_ref(&b), &|_| {})[0].unwrap();
        fs::hard_link(b.join("one"), b.join("two")).unwrap();

        let sizes = measure_all(&[a, b, dir.path().join("missing")], &|_| {});
        assert!(sizes[0].unwrap() >= 100_000);
        assert_eq!(sizes[1].unwrap(), alone);
        assert_eq!(sizes[2], None);
    }
}
