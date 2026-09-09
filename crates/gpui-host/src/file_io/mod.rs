//! Bounded file primitives for scope-owned worker requests.
//!
//! Every path component is opened relative to an owned directory handle
//! without following symbolic links or reparse points, so a substituted link
//! cannot redirect an in-flight operation. Scans are bounded observations, not
//! filesystem snapshots: concurrent removals/changes can fail the entire
//! request. No Roc value, task registry, or GUI state belongs here. The result
//! and error vocabulary is shared; each operating system supplies the
//! primitives behind it.
use std::{
    fs::File,
    io::{self, Read},
    sync::atomic::{AtomicBool, AtomicU64, Ordering},
};

#[cfg(unix)]
mod unix;
#[cfg(unix)]
pub use unix::{list_directory, open_path, read_log, read_preview, read_text, scan, write_text};
#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use windows::{list_directory, open_path, read_log, read_preview, read_text, scan, write_text};

pub const MAX_PATH_BYTES: usize = 4096;
pub const MAX_ERROR_DETAIL_BYTES: usize = 4096;
pub const MAX_TEXT_BYTES: usize = 1024 * 1024;
pub const MAX_SCAN_ENTRIES: usize = 10_000;
pub const MAX_SCAN_DEPTH: usize = 64;
pub const MAX_SCAN_PATH_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_CHUNK_BYTES: usize = 64 * 1024;
pub(super) const CHUNK_BYTES: usize = MAX_CHUNK_BYTES;
pub(super) static TEMP_SERIAL: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, PartialEq, Eq)]
pub struct TextFile {
    pub path: String,
    pub text: String,
}
#[derive(Debug, PartialEq, Eq)]
pub struct Written {
    pub path: String,
    pub bytes: u64,
}
#[derive(Debug, PartialEq, Eq)]
pub struct Entry {
    pub path: String,
    pub kind: Kind,
    pub bytes: u64,
}
#[derive(Debug, PartialEq, Eq)]
pub struct Scan {
    pub root: String,
    pub entries: Vec<Entry>,
}
#[derive(Debug, PartialEq, Eq)]
pub struct DirectoryListing {
    pub path: String,
    pub entries: Vec<Entry>,
}
#[derive(Debug, PartialEq, Eq)]
pub struct Preview {
    pub path: String,
    pub text: String,
    pub truncated: bool,
}
#[derive(Debug, PartialEq, Eq)]
pub struct Opened {
    pub path: String,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LogCursor {
    pub device: u64,
    pub inode: u64,
    pub offset: u64,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LogPosition {
    Start,
    End,
    After(LogCursor),
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LogChange {
    Initial,
    Continued,
    Rotated,
    Truncated,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LogState {
    More,
    AtEnd,
    PartialUtf8,
}
#[derive(Debug, PartialEq, Eq)]
pub struct LogChunk {
    pub path: String,
    pub text: String,
    pub cursor: LogCursor,
    pub change: LogChange,
    pub state: LogState,
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

pub(super) fn utf8_prefix(bytes: &[u8], path: &str) -> Result<usize, FileError> {
    match std::str::from_utf8(bytes) {
        Ok(_) => Ok(bytes.len()),
        Err(error) if error.error_len().is_none() => Ok(error.valid_up_to()),
        Err(_) => Err(FileError::InvalidUtf8(path.into())),
    }
}
