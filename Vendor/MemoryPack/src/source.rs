use std::fs::Metadata;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

use serde::Serialize;

/// Identity and timestamps captured from the validated file used to parse a
/// transcript. `session_id` is internal receipt filtering metadata.
#[derive(Clone, Debug, Serialize)]
pub struct SourceFile {
    pub path: PathBuf,
    pub device: u64,
    pub inode: u64,
    pub size: i64,
    #[serde(rename = "modifiedSeconds")]
    pub modified_seconds: i64,
    #[serde(rename = "modifiedNanoseconds")]
    pub modified_nanoseconds: i64,
    #[serde(rename = "changedSeconds")]
    pub changed_seconds: i64,
    #[serde(rename = "changedNanoseconds")]
    pub changed_nanoseconds: i64,
    #[serde(skip)]
    pub session_id: String,
}

impl SourceFile {
    pub fn from_metadata(path: &Path, metadata: &Metadata, session_id: String) -> Self {
        let path = std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf());
        Self {
            path,
            device: metadata.dev(),
            inode: metadata.ino(),
            size: metadata.len() as i64,
            modified_seconds: metadata.mtime(),
            modified_nanoseconds: metadata.mtime_nsec(),
            changed_seconds: metadata.ctime(),
            changed_nanoseconds: metadata.ctime_nsec(),
            session_id,
        }
    }
}
