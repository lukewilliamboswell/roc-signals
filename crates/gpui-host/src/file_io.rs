//! Bounded Unix file primitives for scope-owned worker requests.
//!
//! All path components are opened relative to owned directory handles with
//! O_NOFOLLOW. A renamed directory remains the same opened directory, and a
//! substituted symlink cannot redirect an in-flight operation. Scans are bounded
//! observations, not filesystem snapshots: concurrent removals/changes can fail
//! the entire request. No Roc value, task registry, or GUI state belongs here.
use std::{
    ffi::{CStr, CString, OsStr},
    fs::File,
    io::{self, Read, Seek, SeekFrom, Write},
    os::{
        fd::{AsRawFd, FromRawFd, IntoRawFd, RawFd},
        unix::ffi::OsStrExt,
    },
    path::{Component, Path},
    sync::atomic::{AtomicBool, AtomicU64, Ordering},
};

pub const MAX_PATH_BYTES: usize = 4096;
pub const MAX_ERROR_DETAIL_BYTES: usize = 4096;
pub const MAX_TEXT_BYTES: usize = 1024 * 1024;
pub const MAX_SCAN_ENTRIES: usize = 10_000;
pub const MAX_SCAN_DEPTH: usize = 64;
pub const MAX_SCAN_PATH_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_CHUNK_BYTES: usize = 64 * 1024;
const CHUNK_BYTES: usize = MAX_CHUNK_BYTES;
static TEMP_SERIAL: AtomicU64 = AtomicU64::new(0);

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

fn canceled(cancel: &AtomicBool) -> Result<(), FileError> {
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

fn io_error(path: &str, error: io::Error) -> FileError {
    let message = bounded_detail(format!("{path}: {error}"));
    match error.raw_os_error() {
        Some(libc::ENOENT) => FileError::NotFound(message),
        Some(libc::EACCES | libc::EPERM) => FileError::PermissionDenied(message),
        Some(libc::ELOOP | libc::ENOTDIR | libc::ENAMETOOLONG | libc::EINVAL) => {
            FileError::InvalidPath(message)
        }
        Some(libc::ENOMEM | libc::EMFILE | libc::ENFILE | libc::ENOSPC | libc::EDQUOT) => {
            FileError::ResourceLimit(message)
        }
        _ => FileError::Io(message),
    }
}

fn path_parts(path: &str) -> Result<Vec<&OsStr>, FileError> {
    if path.len() > MAX_PATH_BYTES {
        return Err(FileError::InvalidPath(
            "path exceeds 4096 UTF-8 bytes".into(),
        ));
    }
    if path.as_bytes().contains(&0) || !Path::new(path).is_absolute() {
        return Err(FileError::InvalidPath(path.into()));
    }
    Path::new(path)
        .components()
        .filter_map(|part| match part {
            Component::RootDir | Component::CurDir => None,
            Component::Normal(name) => Some(Ok(name)),
            _ => Some(Err(FileError::InvalidPath(path.into()))),
        })
        .collect()
}

fn name_cstring(name: &OsStr, path: &str) -> Result<CString, FileError> {
    CString::new(name.as_bytes()).map_err(|_| FileError::InvalidPath(path.into()))
}

fn open_at(
    parent: RawFd,
    name: &OsStr,
    flags: i32,
    mode: libc::mode_t,
    path: &str,
) -> Result<File, FileError> {
    let name = name_cstring(name, path)?;
    // SAFETY: name is NUL-terminated; parent remains owned by the caller. A
    // successful openat returns a fresh descriptor, transferred exactly once.
    let fd = unsafe {
        libc::openat(
            parent,
            name.as_ptr(),
            flags | libc::O_CLOEXEC | libc::O_NOFOLLOW,
            // Darwin's mode_t is u16; C variadic arguments require promotion.
            mode as libc::c_uint,
        )
    };
    if fd < 0 {
        return Err(io_error(path, io::Error::last_os_error()));
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}

fn directory(parts: &[&OsStr], path: &str, cancel: &AtomicBool) -> Result<File, FileError> {
    canceled(cancel)?;
    let mut current = open_at(
        libc::AT_FDCWD,
        OsStr::new("/"),
        libc::O_RDONLY | libc::O_DIRECTORY,
        0,
        path,
    )?;
    for part in parts {
        canceled(cancel)?;
        current = open_at(
            current.as_raw_fd(),
            part,
            libc::O_RDONLY | libc::O_DIRECTORY,
            0,
            path,
        )?;
    }
    Ok(current)
}

fn stat_at(parent: RawFd, name: &OsStr, path: &str) -> Result<libc::stat, FileError> {
    let name = name_cstring(name, path)?;
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    // SAFETY: output points to writable stat storage and no-follow metadata does
    // not open the entry's target. The directory descriptor stays owned above.
    if unsafe {
        libc::fstatat(
            parent,
            name.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } < 0
    {
        return Err(io_error(path, io::Error::last_os_error()));
    }
    Ok(unsafe { stat.assume_init() })
}

fn file_stat(file: &File, path: &str) -> Result<libc::stat, FileError> {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    // SAFETY: the file descriptor is live and output is writable stat storage.
    if unsafe { libc::fstat(file.as_raw_fd(), stat.as_mut_ptr()) } < 0 {
        return Err(io_error(path, io::Error::last_os_error()));
    }
    Ok(unsafe { stat.assume_init() })
}

fn kind(mode: libc::mode_t) -> Kind {
    match mode & libc::S_IFMT {
        libc::S_IFREG => Kind::File,
        libc::S_IFDIR => Kind::Directory,
        libc::S_IFLNK => Kind::SymbolicLink,
        _ => Kind::Other,
    }
}

fn regular_file(path: &str, cancel: &AtomicBool) -> Result<(File, libc::stat), FileError> {
    let parts = path_parts(path)?;
    let (name, parents) = parts
        .split_last()
        .ok_or_else(|| FileError::InvalidPath(path.into()))?;
    let parent = directory(parents, path, cancel)?;
    // O_NONBLOCK prevents a raced FIFO/device replacement from blocking before
    // its kind can be refused; it has no effect on regular-file reads.
    let file = open_at(
        parent.as_raw_fd(),
        name,
        libc::O_RDONLY | libc::O_NONBLOCK,
        0,
        path,
    )?;
    let stat = file_stat(&file, path)?;
    if kind(stat.st_mode) != Kind::File {
        return Err(FileError::InvalidPath(path.into()));
    }
    Ok((file, stat))
}

/// Reads one regular UTF-8 file, checking cancellation between bounded chunks.
/// Symbolic links (including parent components) and special files are refused.
pub fn read_text(path: &str, cancel: &AtomicBool) -> Result<TextFile, FileError> {
    let (mut file, stat) = regular_file(path, cancel)?;
    if stat.st_size > MAX_TEXT_BYTES as i64 {
        return Err(FileError::ResourceLimit(path.into()));
    }
    let mut bytes = Vec::new();
    let mut chunk = [0u8; CHUNK_BYTES];
    loop {
        canceled(cancel)?;
        let count = file
            .read(&mut chunk)
            .map_err(|error| io_error(path, error))?;
        if count == 0 {
            break;
        }
        if bytes.len() + count > MAX_TEXT_BYTES {
            return Err(FileError::ResourceLimit(path.into()));
        }
        bytes
            .try_reserve(count)
            .map_err(|_| FileError::ResourceLimit(path.into()))?;
        bytes.extend_from_slice(&chunk[..count]);
    }
    canceled(cancel)?;
    let text = String::from_utf8(bytes).map_err(|_| FileError::InvalidUtf8(path.into()))?;
    Ok(TextFile {
        path: path.into(),
        text,
    })
}

struct Temporary<'a> {
    parent: &'a File,
    name: CString,
    armed: bool,
}
impl Temporary<'_> {
    fn cleanup(&mut self) -> io::Result<()> {
        if !self.armed {
            return Ok(());
        }
        // SAFETY: the created name is relative to this still-owned directory.
        if unsafe { libc::unlinkat(self.parent.as_raw_fd(), self.name.as_ptr(), 0) } < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ENOENT) {
                return Err(error);
            }
        }
        self.armed = false;
        Ok(())
    }
}
impl Drop for Temporary<'_> {
    fn drop(&mut self) {
        // Normal refusal explicitly reports cleanup errors. This fallback also
        // releases the name if a test callback unwinds before normal cleanup.
        let _ = self.cleanup();
    }
}

/// Atomically replaces one regular file through a same-directory private temp.
/// Existing ordinary permission bits are preserved; new files use mode 0600.
/// Cancellation is checked before rename, which is the commit point: once it
/// succeeds the operation returns Written, even if cancellation races afterward.
/// The file is synchronized before rename; the parent directory is not, so this
/// guarantees atomic replacement rather than power-loss durability. Failed
/// temporary cleanup is reported as Io and can leave the temporary name behind.
/// A blocked syscall keeps its caller's worker reservation until it returns.
pub fn write_text(
    path: &str,
    text: &str,
    cancel: &AtomicBool,
    request_id: u64,
) -> Result<Written, FileError> {
    write_text_before_commit(path, text, cancel, request_id, || {})
}

// The private commit seam makes cancellation and path-race tests deterministic;
// production supplies a no-op and every operation still uses the same worker.
fn write_text_before_commit(
    path: &str,
    text: &str,
    cancel: &AtomicBool,
    request_id: u64,
    before_commit: impl FnOnce(),
) -> Result<Written, FileError> {
    let parts = path_parts(path)?;
    if text.len() > MAX_TEXT_BYTES {
        return Err(FileError::ResourceLimit(path.into()));
    }
    let (name, parents) = parts
        .split_last()
        .ok_or_else(|| FileError::InvalidPath(path.into()))?;
    let parent = directory(parents, path, cancel)?;
    let mode = match stat_at(parent.as_raw_fd(), name, path) {
        Ok(stat) if kind(stat.st_mode) == Kind::File => stat.st_mode & 0o777,
        Ok(_) => return Err(FileError::InvalidPath(path.into())),
        Err(FileError::NotFound(_)) => 0o600,
        Err(error) => return Err(error),
    };
    let mut created = None;
    for _ in 0..32 {
        canceled(cancel)?;
        let serial = TEMP_SERIAL.fetch_add(1, Ordering::Relaxed);
        let temporary = format!(
            ".roc-signals-{}-{request_id}-{serial}.tmp",
            std::process::id()
        );
        let name = CString::new(temporary.as_str()).unwrap();
        // SAFETY: the generated name has no NUL and parent remains live. Capture
        // errno before formatting any diagnostic so only EEXIST is retried.
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_CLOEXEC | libc::O_NOFOLLOW,
                0o600,
            )
        };
        if fd >= 0 {
            created = Some((temporary, unsafe { File::from_raw_fd(fd) }));
            break;
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EEXIST) {
            return Err(io_error(path, error));
        }
    }

    let (temporary_name, mut file) =
        created.ok_or_else(|| FileError::ResourceLimit(path.into()))?;
    let mut temporary = Temporary {
        parent: &parent,
        name: CString::new(temporary_name).unwrap(),
        armed: true,
    };
    let result = (|| {
        for chunk in text.as_bytes().chunks(CHUNK_BYTES) {
            canceled(cancel)?;
            file.write_all(chunk)
                .map_err(|error| io_error(path, error))?;
        }
        canceled(cancel)?;
        // SAFETY: the temporary is a live regular file owned by this request.
        if unsafe { libc::fchmod(file.as_raw_fd(), mode) } < 0 {
            return Err(io_error(path, io::Error::last_os_error()));
        }
        file.sync_all().map_err(|error| io_error(path, error))?;
        before_commit();
        canceled(cancel)?;
        let destination = name_cstring(name, path)?;
        // SAFETY: both names are valid, relative to one live directory descriptor.
        // rename replaces the directory entry itself, never a symlink target.
        if unsafe {
            libc::renameat(
                parent.as_raw_fd(),
                temporary.name.as_ptr(),
                parent.as_raw_fd(),
                destination.as_ptr(),
            )
        } < 0
        {
            return Err(io_error(path, io::Error::last_os_error()));
        }
        temporary.armed = false;
        Ok(Written {
            path: path.into(),
            bytes: text.len() as u64,
        })
    })();
    if let Err(error) = result {
        if let Err(cleanup) = temporary.cleanup() {
            return Err(FileError::Io(bounded_detail(format!(
                "temporary save cleanup failed: {cleanup}; previous failure: {error:?}"
            ))));
        }
        return Err(error);
    }
    result
}

struct ScanBudget {
    entries: Vec<Entry>,
    path_bytes: usize,
}

// Own one native directory stream per active recursion level. Reopening "."
// relative to the retained directory gives the iterator an independent offset;
// dup would share the offset and make a second scan miss entries.
struct DirectoryStream(*mut libc::DIR);

impl DirectoryStream {
    fn open(directory: &File, path: &str) -> Result<Self, FileError> {
        let file = open_at(
            directory.as_raw_fd(),
            OsStr::new("."),
            libc::O_RDONLY | libc::O_DIRECTORY,
            0,
            path,
        )?;
        // SAFETY: file owns a live directory fd. fdopendir takes ownership only
        // on success; on failure File still closes it.
        let stream = unsafe { libc::fdopendir(file.as_raw_fd()) };
        if stream.is_null() {
            return Err(io_error(path, io::Error::last_os_error()));
        }
        let _owned_by_stream = file.into_raw_fd();
        Ok(Self(stream))
    }

    fn next_name(&mut self) -> io::Result<Option<&OsStr>> {
        // SAFETY: this stream is exclusively owned. readdir's name remains
        // valid until the next call on this stream, bounded by the mutable borrow.
        // Clearing thread-local errno distinguishes end-of-directory from error.
        unsafe {
            #[cfg(target_os = "macos")]
            {
                *libc::__error() = 0;
            }
            #[cfg(target_os = "linux")]
            {
                *libc::__errno_location() = 0;
            }
            let entry = libc::readdir(self.0);
            if entry.is_null() {
                let error = io::Error::last_os_error();
                return if error.raw_os_error() == Some(0) {
                    Ok(None)
                } else {
                    Err(error)
                };
            }
            let name = CStr::from_ptr((*entry).d_name.as_ptr());
            Ok(Some(OsStr::from_bytes(name.to_bytes())))
        }
    }
}

impl Drop for DirectoryStream {
    fn drop(&mut self) {
        // SAFETY: the stream owns its descriptor and is closed exactly once,
        // including cancellation, bounded refusal, and recursive scan errors.
        unsafe {
            libc::closedir(self.0);
        }
    }
}

fn scan_directory(
    directory: &File,
    path: &str,
    depth: usize,
    cancel: &AtomicBool,
    budget: &mut ScanBudget,
    recursive: bool,
) -> Result<(), FileError> {
    canceled(cancel)?;
    let mut listing = DirectoryStream::open(directory, path)?;
    while let Some(name) = listing.next_name().map_err(|error| io_error(path, error))? {
        canceled(cancel)?;
        if name == "." || name == ".." {
            continue;
        }
        let name_text = name
            .to_str()
            .ok_or_else(|| FileError::InvalidUtf8(path.into()))?;
        let entry_path = if path == "/" {
            format!("/{name_text}")
        } else {
            format!("{}/{name_text}", path.trim_end_matches('/'))
        };
        if entry_path.len() > MAX_PATH_BYTES
            || budget.entries.len() == MAX_SCAN_ENTRIES
            || budget.path_bytes + entry_path.len() > MAX_SCAN_PATH_BYTES
        {
            return Err(FileError::ResourceLimit(path.into()));
        }
        let stat = stat_at(directory.as_raw_fd(), name, &entry_path)?;
        let entry_kind = kind(stat.st_mode);
        budget
            .entries
            .try_reserve(1)
            .map_err(|_| FileError::ResourceLimit(path.into()))?;
        budget.path_bytes += entry_path.len();
        budget.entries.push(Entry {
            path: entry_path.clone(),
            kind: entry_kind,
            bytes: stat.st_size.max(0) as u64,
        });
        if recursive && entry_kind == Kind::Directory {
            if depth == MAX_SCAN_DEPTH {
                return Err(FileError::ResourceLimit(path.into()));
            }
            let child = open_at(
                directory.as_raw_fd(),
                name,
                libc::O_RDONLY | libc::O_DIRECTORY,
                0,
                &entry_path,
            )?;
            let opened = file_stat(&child, &entry_path)?;
            if opened.st_dev != stat.st_dev || opened.st_ino != stat.st_ino {
                return Err(FileError::Io(bounded_detail(format!(
                    "{entry_path}: entry changed during scan"
                ))));
            }
            scan_directory(&child, &entry_path, depth + 1, cancel, budget, true)?;
        }
    }
    Ok(())
}

/// Recursively observes at most 10,000 entries and 64 directory levels. Symlinks
/// are reported without traversal; any invalid text, race, or exceeded bound
/// refuses the complete result. Returned paths are sorted for stable display.
pub fn scan(root: &str, cancel: &AtomicBool) -> Result<Scan, FileError> {
    let parts = path_parts(root)?;
    let directory = directory(&parts, root, cancel)?;
    let mut budget = ScanBudget {
        entries: Vec::new(),
        path_bytes: root.len(),
    };
    scan_directory(&directory, root, 0, cancel, &mut budget, true)?;
    canceled(cancel)?;
    budget
        .entries
        .sort_unstable_by(|left, right| left.path.cmp(&right.path));
    Ok(Scan {
        root: root.into(),
        entries: budget.entries,
    })
}

/// Lists only direct children through one owned no-follow directory handle.
/// The whole observation is refused above 10,000 entries or four MiB of paths;
/// symlinks are metadata entries and are never followed. Results are path-sorted.
pub fn list_directory(path: &str, cancel: &AtomicBool) -> Result<DirectoryListing, FileError> {
    let parts = path_parts(path)?;
    let directory = directory(&parts, path, cancel)?;
    let mut budget = ScanBudget {
        entries: Vec::new(),
        path_bytes: path.len(),
    };
    scan_directory(&directory, path, 0, cancel, &mut budget, false)?;
    canceled(cancel)?;
    budget
        .entries
        .sort_unstable_by(|left, right| left.path.cmp(&right.path));
    Ok(DirectoryListing {
        path: path.into(),
        entries: budget.entries,
    })
}

// Retain at most the requested byte count. A read can end between UTF-8 code
// points; callers decide whether an incomplete tail is a prefix or pending data.
fn read_chunk(
    file: &mut File,
    path: &str,
    cancel: &AtomicBool,
    count: usize,
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

fn utf8_prefix(bytes: &[u8], path: &str) -> Result<usize, FileError> {
    match std::str::from_utf8(bytes) {
        Ok(_) => Ok(bytes.len()),
        Err(error) if error.error_len().is_none() => Ok(error.valid_up_to()),
        Err(_) => Err(FileError::InvalidUtf8(path.into())),
    }
}

/// Reads a UTF-8 prefix of at most 64 KiB, reporting omitted bytes explicitly.
/// A code point cut by the prefix bound is excluded; invalid UTF-8 inside the
/// prefix or an incomplete terminal code point in a complete file is refused.
pub fn read_preview(path: &str, cancel: &AtomicBool) -> Result<Preview, FileError> {
    let (mut file, _) = regular_file(path, cancel)?;
    let mut bytes = read_chunk(&mut file, path, cancel, MAX_CHUNK_BYTES + 1)?;
    let truncated = bytes.len() > MAX_CHUNK_BYTES;
    bytes.truncate(MAX_CHUNK_BYTES);
    let valid = utf8_prefix(&bytes, path)?;
    if !truncated && valid != bytes.len() {
        return Err(FileError::InvalidUtf8(path.into()));
    }
    bytes.truncate(valid);
    Ok(Preview {
        path: path.into(),
        text: String::from_utf8(bytes).unwrap(),
        truncated,
    })
}

/// Reads at most 64 KiB from a caller-owned cursor; the host retains no file or
/// cursor between requests. A changed device/inode restarts at zero as Rotated;
/// a shorter file restarts as Truncated. Same-inode truncate-and-regrow between
/// observations cannot be distinguished. Start reads history; End seeds EOF
/// after validating its terminal code point (not the skipped history). An
/// incomplete or invalid EOF code point refuses End with InvalidUtf8.
/// Only complete UTF-8 is consumed, so a partial terminal code point is retried
/// from the returned offset. Invalid bytes refuse the request. Line assembly is
/// the caller's bounded responsibility, and concurrent writes are observations,
/// not snapshots. Cancellation closes the request's independently owned file.
pub fn read_log(
    path: &str,
    position: LogPosition,
    cancel: &AtomicBool,
) -> Result<LogChunk, FileError> {
    let (mut file, stat) = regular_file(path, cancel)?;
    let size = u64::try_from(stat.st_size).map_err(|_| FileError::InvalidPath(path.into()))?;
    let mut cursor = LogCursor {
        device: stat.st_dev,
        inode: stat.st_ino,
        offset: 0,
    };
    let change = match position {
        LogPosition::Start => LogChange::Initial,
        LogPosition::End => {
            cursor.offset = size;
            LogChange::Initial
        }
        LogPosition::After(previous)
            if previous.device != cursor.device || previous.inode != cursor.inode =>
        {
            LogChange::Rotated
        }
        LogPosition::After(previous) if previous.offset > size => LogChange::Truncated,
        LogPosition::After(previous) => {
            cursor.offset = previous.offset;
            LogChange::Continued
        }
    };
    if matches!(position, LogPosition::End) {
        // End skips history, but must not seed a continuation in the middle of
        // a code point. Four trailing bytes contain any complete UTF-8 endpoint.
        file.seek(SeekFrom::Start(size.saturating_sub(4)))
            .map_err(|error| io_error(path, error))?;
        let tail = read_chunk(&mut file, path, cancel, size.min(4) as usize)?;
        if !tail.is_empty() {
            let mut start = tail.len() - 1;
            while start > 0 && tail[start] & 0xc0 == 0x80 {
                start -= 1;
            }
            std::str::from_utf8(&tail[start..]).map_err(|_| FileError::InvalidUtf8(path.into()))?;
        }
        canceled(cancel)?;
        return Ok(LogChunk {
            path: path.into(),
            text: String::new(),
            cursor,
            change,
            state: LogState::AtEnd,
        });
    }
    file.seek(SeekFrom::Start(cursor.offset))
        .map_err(|error| io_error(path, error))?;
    let mut bytes = read_chunk(&mut file, path, cancel, MAX_CHUNK_BYTES + 1)?;
    let more = bytes.len() > MAX_CHUNK_BYTES;
    bytes.truncate(MAX_CHUNK_BYTES);
    let valid = utf8_prefix(&bytes, path)?;
    let state = if more {
        LogState::More
    } else if valid != bytes.len() {
        LogState::PartialUtf8
    } else {
        LogState::AtEnd
    };
    bytes.truncate(valid);
    cursor.offset = cursor
        .offset
        .checked_add(valid as u64)
        .ok_or_else(|| FileError::ResourceLimit(path.into()))?;
    Ok(LogChunk {
        path: path.into(),
        text: String::from_utf8(bytes).unwrap(),
        cursor,
        change,
        state,
    })
}

/// Requests the Linux desktop's associated application through `gio open`.
/// Success means the desktop accepted the launch; it does not own the resulting
/// application. Cancellation/deadline kills and reaps the launcher but cannot
/// undo a launch already handed off. The path is validated through no-follow
/// handles first; the external application subsequently resolves that path and
/// owns its own access policy. Launcher stdout/stderr are never retained.
pub fn open_path(path: &str, cancel: &AtomicBool) -> Result<Opened, FileError> {
    open_path_with_launcher(path, cancel, OsStr::new("gio"))
}

fn open_path_with_launcher(
    path: &str,
    cancel: &AtomicBool,
    launcher: &OsStr,
) -> Result<Opened, FileError> {
    use std::{
        process::{Command, Stdio},
        time::{Duration, Instant},
    };
    let (_file, _) = regular_file(path, cancel)?;
    canceled(cancel)?;
    let mut child = Command::new(launcher)
        .arg("open")
        .arg(path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| {
            FileError::Unavailable(bounded_detail(format!("desktop file launcher: {error}")))
        })?;
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return Ok(Opened { path: path.into() }),
            Ok(Some(status)) => {
                return Err(FileError::Unavailable(format!(
                    "desktop file launcher exited with {status}"
                )));
            }
            Ok(None) => (),
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(FileError::Unavailable(bounded_detail(format!(
                    "desktop file launcher: {error}"
                ))));
            }
        }
        if cancel.load(Ordering::Acquire) || Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return if cancel.load(Ordering::Acquire) {
                Err(FileError::Canceled)
            } else {
                Err(FileError::Unavailable(
                    "desktop file launcher timed out".into(),
                ))
            };
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    #[cfg(target_os = "linux")]
    use std::os::unix::ffi::OsStringExt;
    use std::os::unix::fs::{PermissionsExt, symlink};

    struct Directory(std::path::PathBuf);
    impl Directory {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "signals-file-test-{}-{}",
                std::process::id(),
                TEMP_SERIAL.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&root).unwrap();
            // macOS temp_dir starts with /var, a symlink to /private/var.
            // Tests need a real parent path to exercise the no-follow contract.
            Self(root.canonicalize().unwrap())
        }
        fn path(&self, name: &str) -> String {
            self.0.join(name).to_str().unwrap().into()
        }
        fn root(&self) -> &str {
            self.0.to_str().unwrap()
        }
        fn names(&self) -> Vec<String> {
            let mut names: Vec<_> = fs::read_dir(&self.0)
                .unwrap()
                .map(|entry| entry.unwrap().file_name().into_string().unwrap())
                .collect();
            names.sort();
            names
        }
    }
    impl Drop for Directory {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    fn active() -> AtomicBool {
        AtomicBool::new(false)
    }

    #[test]
    fn direct_listing_does_not_descend_and_refuses_entry_overflow() {
        let dir = Directory::new();
        fs::create_dir(dir.path("child")).unwrap();
        fs::write(dir.path("child/hidden.txt"), "nested").unwrap();
        symlink(dir.path("child"), dir.path("link")).unwrap();
        let listing = list_directory(dir.root(), &active()).unwrap();
        assert_eq!(listing.entries.len(), 2);
        assert_eq!(listing.entries[0].kind, Kind::Directory);
        assert_eq!(listing.entries[1].kind, Kind::SymbolicLink);
        assert_eq!(
            list_directory(&dir.path("child"), &active())
                .unwrap()
                .entries
                .len(),
            1
        );
        assert!(matches!(
            list_directory(&dir.path("link"), &active()),
            Err(FileError::InvalidPath(_))
        ));
        assert_eq!(
            list_directory(dir.root(), &AtomicBool::new(true)),
            Err(FileError::Canceled)
        );
        for index in 0..MAX_SCAN_ENTRIES - 2 {
            fs::write(dir.path(&format!("entry-{index}")), "").unwrap();
        }
        assert_eq!(
            list_directory(dir.root(), &active()).unwrap().entries.len(),
            MAX_SCAN_ENTRIES
        );
        fs::write(dir.path("overflow"), "").unwrap();
        assert!(matches!(
            list_directory(dir.root(), &active()),
            Err(FileError::ResourceLimit(_))
        ));
    }

    #[test]
    fn preview_preserves_utf8_and_distinguishes_prefix_from_invalid_content() {
        let dir = Directory::new();
        let path = dir.path("preview.txt");
        fs::write(&path, format!("{}λtail", "x".repeat(MAX_CHUNK_BYTES - 1))).unwrap();
        let preview = read_preview(&path, &active()).unwrap();
        assert!(preview.truncated);
        assert_eq!(preview.text.len(), MAX_CHUNK_BYTES - 1);
        fs::write(&path, "x".repeat(MAX_CHUNK_BYTES)).unwrap();
        assert!(!read_preview(&path, &active()).unwrap().truncated);
        for bytes in [&b"invalid\xffbytes"[..], &b"partial\xce"[..]] {
            fs::write(&path, bytes).unwrap();
            assert!(matches!(
                read_preview(&path, &active()),
                Err(FileError::InvalidUtf8(_))
            ));
        }
        assert_eq!(
            read_preview(&path, &AtomicBool::new(true)),
            Err(FileError::Canceled)
        );
    }

    #[test]
    fn log_cursor_handles_append_partial_utf8_truncation_and_rotation() {
        let dir = Directory::new();
        let path = dir.path("events.log");
        fs::write(&path, b"first\npart\xce").unwrap();
        let first = read_log(&path, LogPosition::Start, &active()).unwrap();
        assert_eq!(first.text, "first\npart");
        assert_eq!(first.cursor.offset, 10);
        assert_eq!(first.change, LogChange::Initial);
        assert_eq!(first.state, LogState::PartialUtf8);
        assert!(matches!(
            read_log(&path, LogPosition::End, &active()),
            Err(FileError::InvalidUtf8(_))
        ));
        fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap()
            .write_all(b"\xbb\nnext")
            .unwrap();
        let second = read_log(&path, LogPosition::After(first.cursor), &active()).unwrap();
        assert_eq!(second.text, "λ\nnext");
        assert_eq!(second.change, LogChange::Continued);
        assert_eq!(second.state, LogState::AtEnd);
        let end = read_log(&path, LogPosition::End, &active()).unwrap();
        assert_eq!(end.cursor, second.cursor);
        assert!(end.text.is_empty());
        fs::write(&path, "short").unwrap();
        let truncated = read_log(&path, LogPosition::After(second.cursor), &active()).unwrap();
        assert_eq!(truncated.change, LogChange::Truncated);
        assert_eq!(truncated.text, "short");
        fs::rename(&path, dir.path("old.log")).unwrap();
        fs::write(&path, "rotated\n").unwrap();
        let rotated = read_log(&path, LogPosition::After(truncated.cursor), &active()).unwrap();
        assert_eq!(rotated.change, LogChange::Rotated);
        assert_eq!(rotated.text, "rotated\n");
        assert_ne!(rotated.cursor.inode, truncated.cursor.inode);
        assert_eq!(
            read_log(&path, LogPosition::Start, &AtomicBool::new(true)),
            Err(FileError::Canceled)
        );
    }

    #[test]
    fn log_bound_never_consumes_partial_codepoint_and_end_rejects_bad_endpoint() {
        let dir = Directory::new();
        let path = dir.path("events.log");
        fs::write(&path, format!("{}λtail", "x".repeat(MAX_CHUNK_BYTES - 1))).unwrap();
        let first = read_log(&path, LogPosition::Start, &active()).unwrap();
        assert_eq!(first.text.len(), MAX_CHUNK_BYTES - 1);
        assert_eq!(first.cursor.offset, (MAX_CHUNK_BYTES - 1) as u64);
        assert_eq!(first.state, LogState::More);
        let second = read_log(&path, LogPosition::After(first.cursor), &active()).unwrap();
        assert_eq!(second.text, "λtail");
        assert_eq!(second.state, LogState::AtEnd);
        for text in ["", "λ", "ab🦀", "xé", "🦀é"] {
            fs::write(&path, text).unwrap();
            assert_eq!(
                read_log(&path, LogPosition::End, &active())
                    .unwrap()
                    .cursor
                    .offset,
                text.len() as u64
            );
        }
        fs::write(&path, b"\xff").unwrap();
        assert!(matches!(
            read_log(&path, LogPosition::Start, &active()),
            Err(FileError::InvalidUtf8(_))
        ));
        assert!(matches!(
            read_log(&path, LogPosition::End, &active()),
            Err(FileError::InvalidUtf8(_))
        ));
        fs::write(&path, b"x\xf0\x9f\xa6").unwrap();
        let partial = read_log(&path, LogPosition::Start, &active()).unwrap();
        assert_eq!(partial.text, "x");
        assert_eq!(partial.cursor.offset, 1);
        assert_eq!(partial.state, LogState::PartialUtf8);
        assert!(matches!(
            read_log(&path, LogPosition::End, &active()),
            Err(FileError::InvalidUtf8(_))
        ));
    }

    #[test]
    fn associated_open_reports_launcher_result_and_cancels_without_launching() {
        let dir = Directory::new();
        let path = dir.path("file.txt");
        fs::write(&path, "document").unwrap();
        assert_eq!(
            open_path_with_launcher(&path, &active(), OsStr::new("/usr/bin/true"))
                .unwrap()
                .path,
            path
        );
        assert!(matches!(
            open_path_with_launcher(&path, &active(), OsStr::new("/usr/bin/false")),
            Err(FileError::Unavailable(_))
        ));
        assert_eq!(
            open_path_with_launcher(
                &path,
                &AtomicBool::new(true),
                OsStr::new("/missing-launcher")
            ),
            Err(FileError::Canceled)
        );
        assert!(matches!(
            open_path_with_launcher(&path, &active(), OsStr::new("/missing-launcher")),
            Err(FileError::Unavailable(_))
        ));
    }

    #[test]
    fn utf8_save_replaces_snapshot_atomically_and_preserves_regular_permissions() {
        let dir = Directory::new();
        let path = dir.path("café.txt");
        let text = "First line\nSecond 🦀 café\n";
        let result = write_text(&path, text, &active(), 1).unwrap();
        assert_eq!(result.bytes, text.len() as u64);
        assert_eq!(read_text(&path, &active()).unwrap().text, text);
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();
        write_text(&path, "", &active(), 2).unwrap();
        assert_eq!(read_text(&path, &active()).unwrap().text, "");
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o640
        );
        assert_eq!(dir.names(), vec!["café.txt"]);
    }

    #[test]
    fn canceled_save_before_commit_preserves_previous_bytes_and_cleans_temporary() {
        let dir = Directory::new();
        let path = dir.path("draft.txt");
        fs::write(&path, "original").unwrap();
        let cancel = active();
        assert_eq!(
            write_text_before_commit(&path, &"x".repeat(CHUNK_BYTES * 2), &cancel, 3, || cancel
                .store(true, Ordering::Release)),
            Err(FileError::Canceled)
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), "original");
        assert_eq!(dir.names(), vec!["draft.txt"]);
        assert_eq!(read_text(&path, &cancel), Err(FileError::Canceled));
        assert_eq!(scan(dir.root(), &cancel), Err(FileError::Canceled));
        assert_eq!(
            write_text(&path, "next", &cancel, 4),
            Err(FileError::Canceled)
        );
        cancel.store(false, Ordering::Release);
        write_text(&path, "retry", &cancel, 5).unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "retry");
    }

    #[test]
    fn rename_refusal_cleans_temporary_and_preserves_the_new_destination() {
        let dir = Directory::new();
        let path = dir.path("draft.txt");
        fs::write(&path, "original").unwrap();
        let result = write_text_before_commit(&path, "replacement", &active(), 6, || {
            fs::remove_file(&path).unwrap();
            fs::create_dir(&path).unwrap();
        });
        assert!(result.is_err());
        assert!(fs::metadata(&path).unwrap().is_dir());
        assert_eq!(dir.names(), vec!["draft.txt"]);
    }

    #[test]
    fn cleanup_refusal_is_reported_instead_of_discarding_a_retained_temporary() {
        // Root bypasses directory permission checks; CI and normal development
        // run this invariant as an ordinary user.
        if unsafe { libc::geteuid() } == 0 {
            return;
        }
        let dir = Directory::new();
        let path = dir.path("draft");
        fs::write(&path, "original").unwrap();
        let cancel = active();
        let result = write_text_before_commit(&path, "replacement", &cancel, 13, || {
            fs::set_permissions(&dir.0, fs::Permissions::from_mode(0o500)).unwrap();
            cancel.store(true, Ordering::Release);
        });
        fs::set_permissions(&dir.0, fs::Permissions::from_mode(0o700)).unwrap();
        let Err(FileError::Io(message)) = result else {
            panic!("cleanup refusal was hidden")
        };
        assert!(message.contains("temporary save cleanup failed"));
        assert_eq!(fs::read_to_string(&path).unwrap(), "original");
        assert_eq!(dir.names().len(), 2);
    }

    #[test]
    fn no_follow_handles_resist_parent_and_destination_symlink_replacement() {
        let dir = Directory::new();
        let safe = dir.path("safe");
        let moved = dir.path("moved");
        let outside = dir.path("outside");
        fs::create_dir(&safe).unwrap();
        fs::create_dir(&outside).unwrap();
        let target = format!("{safe}/note");
        let outside_target = format!("{outside}/note");
        fs::write(&target, "old").unwrap();
        fs::write(&outside_target, "outside").unwrap();
        write_text_before_commit(&target, "inside", &active(), 7, || {
            fs::rename(&safe, &moved).unwrap();
            symlink(&outside, &safe).unwrap();
            fs::remove_file(format!("{moved}/note")).unwrap();
            symlink(&outside_target, format!("{moved}/note")).unwrap();
        })
        .unwrap();
        assert_eq!(
            fs::read_to_string(format!("{moved}/note")).unwrap(),
            "inside"
        );
        assert!(
            !fs::symlink_metadata(format!("{moved}/note"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(fs::read_to_string(&outside_target).unwrap(), "outside");
        assert!(matches!(
            read_text(&target, &active()),
            Err(FileError::InvalidPath(_))
        ));
        assert!(matches!(
            write_text(&target, "wrong", &active(), 8),
            Err(FileError::InvalidPath(_))
        ));
        assert!(matches!(
            scan(&safe, &active()),
            Err(FileError::InvalidPath(_))
        ));
    }

    #[test]
    fn scan_reports_symlink_cycles_and_special_files_without_traversing() {
        let dir = Directory::new();
        fs::create_dir(dir.path("folder")).unwrap();
        fs::write(dir.path("folder/data"), "abc").unwrap();
        symlink(dir.root(), dir.path("folder/loop")).unwrap();
        let fifo = CString::new(dir.path("pipe")).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
        let result = scan(dir.root(), &active()).unwrap();
        assert_eq!(result.entries.len(), 4);
        assert_eq!(
            result.entries.iter().map(|e| e.kind).collect::<Vec<_>>(),
            vec![Kind::Directory, Kind::File, Kind::SymbolicLink, Kind::Other]
        );
        assert_eq!(result.entries[1].bytes, 3);
        assert!(matches!(
            read_text(&dir.path("pipe"), &active()),
            Err(FileError::InvalidPath(_))
        ));
        assert!(matches!(
            write_text(&dir.path("pipe"), "x", &active(), 9),
            Err(FileError::InvalidPath(_))
        ));
        assert!(matches!(
            read_text(&dir.path("folder/loop"), &active()),
            Err(FileError::InvalidPath(_))
        ));
    }

    #[test]
    fn text_limits_utf8_and_invalid_paths_refuse_without_partial_writes() {
        let dir = Directory::new();
        let path = dir.path("draft");
        let limit = "x".repeat(MAX_TEXT_BYTES);
        write_text(&path, &limit, &active(), 10).unwrap();
        assert_eq!(
            read_text(&path, &active()).unwrap().text.len(),
            MAX_TEXT_BYTES
        );
        assert!(matches!(
            write_text(&path, &(limit.clone() + "x"), &active(), 11),
            Err(FileError::ResourceLimit(_))
        ));
        assert_eq!(fs::metadata(&path).unwrap().len(), MAX_TEXT_BYTES as u64);
        fs::write(&path, limit + "x").unwrap();
        assert!(matches!(
            read_text(&path, &active()),
            Err(FileError::ResourceLimit(_))
        ));
        fs::write(&path, [0xff, 0xfe]).unwrap();
        assert!(matches!(
            read_text(&path, &active()),
            Err(FileError::InvalidUtf8(_))
        ));
        for path in ["relative", "/tmp/../escape", "/tmp/a\0b"] {
            assert!(matches!(
                read_text(path, &active()),
                Err(FileError::InvalidPath(_))
            ));
        }
        let oversized = format!("/{}", "é".repeat(MAX_PATH_BYTES));
        let Err(FileError::InvalidPath(message)) = write_text(&oversized, "", &active(), 12) else {
            panic!("invalid long path accepted")
        };
        assert!(message.len() <= MAX_PATH_BYTES);
        assert_eq!(dir.names(), vec!["draft"]);
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn scan_rejects_non_utf8_entry_names() {
        // APFS rejects this name before the scan can observe it.
        let dir = Directory::new();
        let invalid_name = dir.0.join(std::ffi::OsString::from_vec(vec![0xff]));
        fs::write(&invalid_name, "x").unwrap();
        assert!(matches!(
            scan(dir.root(), &active()),
            Err(FileError::InvalidUtf8(_))
        ));
    }

    #[test]
    fn scan_rejects_complete_results_over_each_bound() {
        let dir = Directory::new();
        fs::write(dir.path("entry"), "x").unwrap();
        let parts = path_parts(dir.root()).unwrap();
        let handle = directory(&parts, dir.root(), &active()).unwrap();
        let mut count_limit = ScanBudget {
            entries: (0..MAX_SCAN_ENTRIES)
                .map(|_| Entry {
                    path: String::new(),
                    kind: Kind::File,
                    bytes: 0,
                })
                .collect(),
            path_bytes: 0,
        };
        assert!(matches!(
            scan_directory(&handle, dir.root(), 0, &active(), &mut count_limit, true),
            Err(FileError::ResourceLimit(_))
        ));
        assert_eq!(count_limit.entries.len(), MAX_SCAN_ENTRIES);
        let mut path_limit = ScanBudget {
            entries: Vec::new(),
            path_bytes: MAX_SCAN_PATH_BYTES,
        };
        assert!(matches!(
            scan_directory(&handle, dir.root(), 0, &active(), &mut path_limit, true),
            Err(FileError::ResourceLimit(_))
        ));
        assert!(path_limit.entries.is_empty());
        fs::create_dir(dir.path("folder")).unwrap();
        let mut depth_limit = ScanBudget {
            entries: Vec::new(),
            path_bytes: 0,
        };
        assert!(matches!(
            scan_directory(
                &handle,
                dir.root(),
                MAX_SCAN_DEPTH,
                &active(),
                &mut depth_limit,
                true,
            ),
            Err(FileError::ResourceLimit(_))
        ));
    }

    #[test]
    fn repeated_scans_keep_the_opened_directory_after_path_replacement() {
        let dir = Directory::new();
        let original = dir.path("original");
        let moved = dir.path("moved");
        let replacement = dir.path("replacement");
        fs::create_dir(&original).unwrap();
        fs::create_dir(&replacement).unwrap();
        fs::write(format!("{original}/retained"), "old").unwrap();
        fs::write(format!("{replacement}/redirected"), "new").unwrap();
        let parts = path_parts(&original).unwrap();
        let handle = directory(&parts, &original, &active()).unwrap();
        fs::rename(&original, &moved).unwrap();
        symlink(&replacement, &original).unwrap();
        for _ in 0..2 {
            let mut budget = ScanBudget {
                entries: Vec::new(),
                path_bytes: original.len(),
            };
            scan_directory(&handle, &original, 0, &active(), &mut budget, true).unwrap();
            assert_eq!(budget.entries.len(), 1);
            assert_eq!(budget.entries[0].path, format!("{original}/retained"));
        }
    }

    #[test]
    fn actual_scan_accepts_depth_64_and_refuses_depth_65() {
        let dir = Directory::new();
        let mut path = dir.0.clone();
        for _ in 0..MAX_SCAN_DEPTH {
            path.push("d");
            fs::create_dir(&path).unwrap();
        }
        assert_eq!(
            scan(dir.root(), &active()).unwrap().entries.len(),
            MAX_SCAN_DEPTH
        );
        path.push("d");
        fs::create_dir(&path).unwrap();
        assert!(matches!(
            scan(dir.root(), &active()),
            Err(FileError::ResourceLimit(_))
        ));
    }
}
