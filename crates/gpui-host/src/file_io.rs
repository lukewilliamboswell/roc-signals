//! Bounded Linux file primitives for scope-owned worker requests.
//!
//! All path components are opened relative to owned directory handles with
//! O_NOFOLLOW. A renamed directory remains the same opened directory, and a
//! substituted symlink cannot redirect an in-flight operation. Scans are bounded
//! observations, not filesystem snapshots: concurrent removals/changes can fail
//! the entire request. No Roc value, task registry, or GUI state belongs here.
use std::{
    ffi::{CString, OsStr},
    fs::{self, File},
    io::{self, Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd, RawFd},
        unix::ffi::OsStrExt,
    },
    path::{Component, Path},
    sync::atomic::{AtomicBool, AtomicU64, Ordering},
};

pub const MAX_PATH_BYTES: usize = 4096;
pub const MAX_TEXT_BYTES: usize = 1024 * 1024;
pub const MAX_SCAN_ENTRIES: usize = 10_000;
pub const MAX_SCAN_DEPTH: usize = 64;
pub const MAX_SCAN_PATH_BYTES: usize = 4 * 1024 * 1024;
const CHUNK_BYTES: usize = 64 * 1024;
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

fn bounded_detail(mut message: String) -> String {
    if message.len() > MAX_PATH_BYTES {
        let mut end = MAX_PATH_BYTES;
        while !message.is_char_boundary(end) {
            end -= 1;
        }
        message.truncate(end);
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
            mode,
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

/// Reads one regular UTF-8 file, checking cancellation between bounded chunks.
/// Symbolic links (including parent components) and special files are refused.
pub fn read_text(path: &str, cancel: &AtomicBool) -> Result<TextFile, FileError> {
    let parts = path_parts(path)?;
    let (name, parents) = parts
        .split_last()
        .ok_or_else(|| FileError::InvalidPath(path.into()))?;
    let parent = directory(parents, path, cancel)?;
    // O_NONBLOCK prevents a raced FIFO/device replacement from blocking before
    // its kind can be refused; it has no effect on regular-file reads.
    let mut file = open_at(
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

fn scan_directory(
    directory: &File,
    path: &str,
    depth: usize,
    cancel: &AtomicBool,
    budget: &mut ScanBudget,
) -> Result<(), FileError> {
    canceled(cancel)?;
    // /proc/self/fd resolves our still-owned descriptor, not an application path.
    // read_dir owns its iterator handle while recursion owns each no-follow fd.
    let listing = fs::read_dir(format!("/proc/self/fd/{}", directory.as_raw_fd()))
        .map_err(|error| io_error(path, error))?;
    for entry in listing {
        canceled(cancel)?;
        let entry = entry.map_err(|error| io_error(path, error))?;
        let name = entry.file_name();
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
        let stat = stat_at(directory.as_raw_fd(), &name, &entry_path)?;
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
        if entry_kind == Kind::Directory {
            if depth == MAX_SCAN_DEPTH {
                return Err(FileError::ResourceLimit(path.into()));
            }
            let child = open_at(
                directory.as_raw_fd(),
                &name,
                libc::O_RDONLY | libc::O_DIRECTORY,
                0,
                &entry_path,
            )?;
            let opened = file_stat(&child, &entry_path)?;
            if opened.st_dev != stat.st_dev || opened.st_ino != stat.st_ino {
                return Err(FileError::Io(format!(
                    "{entry_path}: entry changed during scan"
                )));
            }
            scan_directory(&child, &entry_path, depth + 1, cancel, budget)?;
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
    scan_directory(&directory, root, 0, cancel, &mut budget)?;
    canceled(cancel)?;
    budget
        .entries
        .sort_unstable_by(|left, right| left.path.cmp(&right.path));
    Ok(Scan {
        root: root.into(),
        entries: budget.entries,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::{
        ffi::OsStringExt,
        fs::{PermissionsExt, symlink},
    };

    struct Directory(std::path::PathBuf);
    impl Directory {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "signals-file-test-{}-{}",
                std::process::id(),
                TEMP_SERIAL.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&root).unwrap();
            Self(root)
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
    fn scan_rejects_non_utf8_entry_names_and_complete_results_over_each_bound() {
        let dir = Directory::new();
        let invalid_name = dir.0.join(std::ffi::OsString::from_vec(vec![0xff]));
        fs::write(&invalid_name, "x").unwrap();
        assert!(matches!(
            scan(dir.root(), &active()),
            Err(FileError::InvalidUtf8(_))
        ));
        fs::remove_file(invalid_name).unwrap();
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
            scan_directory(&handle, dir.root(), 0, &active(), &mut count_limit),
            Err(FileError::ResourceLimit(_))
        ));
        assert_eq!(count_limit.entries.len(), MAX_SCAN_ENTRIES);
        let mut path_limit = ScanBudget {
            entries: Vec::new(),
            path_bytes: MAX_SCAN_PATH_BYTES,
        };
        assert!(matches!(
            scan_directory(&handle, dir.root(), 0, &active(), &mut path_limit),
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
                &mut depth_limit
            ),
            Err(FileError::ResourceLimit(_))
        ));
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
