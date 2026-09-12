use std::fs::{File, Metadata, OpenOptions};
use std::io;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;
use std::time::UNIX_EPOCH;

#[derive(Debug)]
pub enum StableInputError {
    Io,
    Symlink,
    NotRegular,
    Changed,
}

impl From<io::Error> for StableInputError {
    fn from(_: io::Error) -> Self {
        Self::Io
    }
}

pub fn open_regular_expected(
    path: &Path,
    expected: Option<&Metadata>,
) -> Result<(File, Metadata), StableInputError> {
    let before = regular_metadata(path)?;
    if expected.is_some_and(|expected| !same_identity(expected, &before)) {
        return Err(StableInputError::Changed);
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc_flags())
        .open(path)?;
    let opened = file.metadata()?;
    if !same_identity(&before, &opened) {
        return Err(StableInputError::Changed);
    }
    Ok((file, before))
}

pub fn regular_metadata(path: &Path) -> Result<Metadata, StableInputError> {
    let ancestors: Vec<_> = path.ancestors().collect();
    for ancestor in ancestors.into_iter().rev() {
        let info = ancestor.symlink_metadata()?;
        if info.file_type().is_symlink() {
            return Err(StableInputError::Symlink);
        }
    }
    let info = path.symlink_metadata()?;
    if !info.file_type().is_file() {
        return Err(StableInputError::NotRegular);
    }
    Ok(info)
}

pub fn unchanged(path: &Path, file: &File, before: &Metadata) -> Result<(), StableInputError> {
    let after_fd = file.metadata()?;
    let after_path = regular_metadata(path)?;
    if same_identity(before, &after_fd) && same_identity(before, &after_path) {
        Ok(())
    } else {
        Err(StableInputError::Changed)
    }
}

pub fn modified_epoch(metadata: &Metadata) -> Option<f64> {
    metadata
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|value| value.as_secs_f64())
}

pub fn is_before_cutoff(modified: Option<f64>, cutoff: f64) -> bool {
    modified.is_some_and(|value| value < cutoff)
}

pub fn same_identity(left: &Metadata, right: &Metadata) -> bool {
    left.dev() == right.dev()
        && left.ino() == right.ino()
        && left.mode() == right.mode()
        && left.len() == right.len()
        && left.mtime_nsec() == right.mtime_nsec()
        && left.ctime_nsec() == right.ctime_nsec()
        && left.mtime() == right.mtime()
        && left.ctime() == right.ctime()
}

#[cfg(target_os = "macos")]
fn libc_flags() -> i32 {
    // Darwin fcntl.h: O_NOFOLLOW=0x100, O_NONBLOCK=0x4, O_CLOEXEC=0x1000000.
    0x0000_0100 | 0x0000_0004 | 0x0100_0000
}

#[cfg(not(target_os = "macos"))]
fn libc_flags() -> i32 {
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn fixture_path(name: &str) -> std::path::PathBuf {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let temporary = std::env::temp_dir()
            .to_string_lossy()
            .replace("/var/", "/private/var/");
        std::path::PathBuf::from(temporary).join(format!(
            "memory-pack-input-{}-{stamp}-{name}",
            std::process::id()
        ))
    }

    #[test]
    fn cutoff_is_strict_and_excludes_recent_or_unknown_files() {
        assert!(is_before_cutoff(Some(99.0), 100.0));
        assert!(!is_before_cutoff(Some(100.0), 100.0));
        assert!(!is_before_cutoff(Some(101.0), 100.0));
        assert!(!is_before_cutoff(None, 100.0));
    }

    #[test]
    fn rejects_symlink_ancestors() {
        let root = fixture_path("symlink-root");
        let real = fixture_path("real-root");
        let _ = fs::create_dir_all(&real);
        std::os::unix::fs::symlink(&real, &root).unwrap();
        let path = root.join("session.jsonl");
        assert!(matches!(
            regular_metadata(&path),
            Err(StableInputError::Symlink)
        ));
    }

    #[test]
    fn detects_changed_input_after_open() {
        let path = fixture_path("changed.jsonl");
        fs::write(&path, b"before").unwrap();
        let (file, before) = open_regular_expected(&path, None).unwrap();
        fs::write(&path, b"after").unwrap();
        assert!(matches!(
            unchanged(&path, &file, &before),
            Err(StableInputError::Changed)
        ));
    }

    #[test]
    fn detects_deleted_or_replaced_input_after_open() {
        let deleted = fixture_path("deleted.jsonl");
        fs::write(&deleted, b"before").unwrap();
        let (file, before) = open_regular_expected(&deleted, None).unwrap();
        fs::remove_file(&deleted).unwrap();
        assert!(unchanged(&deleted, &file, &before).is_err());

        let replaced = fixture_path("replaced.jsonl");
        fs::write(&replaced, b"before").unwrap();
        let (file, before) = open_regular_expected(&replaced, None).unwrap();
        fs::remove_file(&replaced).unwrap();
        std::os::unix::fs::symlink(&deleted, &replaced).unwrap();
        assert!(matches!(
            unchanged(&replaced, &file, &before),
            Err(StableInputError::Symlink)
        ));
    }

    #[test]
    fn detects_change_between_cutoff_selection_and_open() {
        let path = fixture_path("between-selection-and-open.jsonl");
        fs::write(&path, b"before").unwrap();
        let selected = regular_metadata(&path).unwrap();
        fs::write(&path, b"after").unwrap();
        assert!(matches!(
            open_regular_expected(&path, Some(&selected)),
            Err(StableInputError::Changed)
        ));
    }
}
