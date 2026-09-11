//! Bounded file primitives behind the hosted `Files` functions.
//!
//! Every path component is opened relative to an owned directory handle
//! without following symbolic links or reparse points, so a substituted link
//! cannot redirect an in-flight operation. Listings are bounded observations,
//! not filesystem snapshots: concurrent removals or changes can fail the
//! entire request. No Roc value or GUI state belongs here. The result and
//! error vocabulary is shared; each operating system supplies the primitives
//! behind it.
use std::{
    fs::File,
    io::{self, Read},
    sync::atomic::{AtomicBool, Ordering},
};

#[cfg(unix)]
mod unix;
#[cfg(unix)]
pub use unix::{list_directory, open_path, read_at, remove, rename, stat, sync, write_bytes};
#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use windows::{list_directory, open_path, read_at, remove, rename, stat, sync, write_bytes};

pub const MAX_PATH_BYTES: usize = 4096;
pub const MAX_ERROR_DETAIL_BYTES: usize = 4096;
pub const MAX_SCAN_ENTRIES: usize = 10_000;
pub const MAX_SCAN_DEPTH: usize = 64;
pub const MAX_SCAN_PATH_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_CHUNK_BYTES: usize = 64 * 1024;
pub(super) const CHUNK_BYTES: usize = MAX_CHUNK_BYTES;

#[derive(Debug, PartialEq, Eq)]
pub struct Entry {
    pub path: String,
    pub kind: Kind,
    pub bytes: u64,
}
#[derive(Debug, PartialEq, Eq)]
pub struct DirectoryListing {
    pub path: String,
    pub entries: Vec<Entry>,
}
/// No-follow metadata of one entry; `device` and `inode` identify the file
/// so a follower can notice replacement.
#[derive(Debug, PartialEq, Eq)]
pub struct Metadata {
    pub kind: Kind,
    pub size: u64,
    pub device: u64,
    pub inode: u64,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    File,
    Directory,
    SymbolicLink,
    Other,
}
#[derive(Debug, PartialEq, Eq)]
pub enum FileError {
    Canceled,
    NotFound(String),
    PermissionDenied(String),
    InvalidUtf8(String),
    InvalidPath(String),
    ResourceLimit(String),
    Io(String),
    Unavailable(String),
}

pub(super) fn canceled(cancel: &AtomicBool) -> Result<(), FileError> {
    if cancel.load(Ordering::Acquire) {
        Err(FileError::Canceled)
    } else {
        Ok(())
    }
}

/// Bounds diagnostic text before native result framing, preserving UTF-8 and
/// marking omitted detail. This never changes a task's error code or data result.
pub(crate) fn bounded_detail(mut message: String) -> String {
    const MARKER: &str = " [truncated]";
    if message.len() > MAX_ERROR_DETAIL_BYTES {
        let mut end = MAX_ERROR_DETAIL_BYTES - MARKER.len();
        while !message.is_char_boundary(end) {
            end -= 1;
        }
        message.truncate(end);
        message.push_str(MARKER);
    }
    message
}

// Retain at most the requested byte count. A read can end between UTF-8 code
// points; callers decide whether an incomplete tail is a prefix or pending data.
pub(super) fn read_chunk(
    file: &mut File,
    path: &str,
    cancel: &AtomicBool,
    count: usize,
    io_error: fn(&str, io::Error) -> FileError,
) -> Result<Vec<u8>, FileError> {
    let mut bytes = Vec::new();
    bytes
        .try_reserve_exact(count)
        .map_err(|_| FileError::ResourceLimit(path.into()))?;
    bytes.resize(count, 0);
    let mut used = 0;
    while used < count {
        canceled(cancel)?;
        let read = file
            .read(&mut bytes[used..])
            .map_err(|error| io_error(path, error))?;
        if read == 0 {
            break;
        }
        used += read;
    }
    canceled(cancel)?;
    bytes.truncate(used);
    Ok(bytes)
}
