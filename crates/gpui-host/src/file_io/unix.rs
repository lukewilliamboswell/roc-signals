//! Bounded Unix file primitives behind the hosted `Files` functions.
//!
//! All path components are opened relative to owned directory handles with
//! O_NOFOLLOW. A renamed directory remains the same opened directory, and a
//! substituted symlink cannot redirect an in-flight operation. Listings are
//! bounded observations, not filesystem snapshots: concurrent removals or
//! changes can fail the entire request. No Roc value or GUI state belongs here.
use super::{
    CHUNK_BYTES, DirectoryListing, Entry, FileError, Kind, MAX_PATH_BYTES, MAX_SCAN_DEPTH,
    MAX_SCAN_ENTRIES, MAX_SCAN_PATH_BYTES, Metadata, bounded_detail, canceled, read_chunk,
};
use std::{
    ffi::{CStr, CString, OsStr},
    fs::File,
    io::{self, Seek, SeekFrom, Write},
    os::{
        fd::{AsRawFd, FromRawFd, IntoRawFd, RawFd},
        unix::ffi::OsStrExt,
    },
    path::{Component, Path},
    sync::atomic::{AtomicBool, Ordering},
};

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



/// Requests the Linux desktop's associated application through `gio open`.
/// Success means the desktop accepted the launch; it does not own the resulting
/// application. Cancellation/deadline kills and reaps the launcher but cannot
/// undo a launch already handed off. The path is validated through no-follow
/// handles first; the external application subsequently resolves that path and
/// owns its own access policy. Launcher stdout/stderr are never retained.
pub fn open_path(path: &str, cancel: &AtomicBool) -> Result<(), FileError> {
    open_path_with_launcher(path, cancel, OsStr::new("gio"))
}

fn open_path_with_launcher(
    path: &str,
    cancel: &AtomicBool,
    launcher: &OsStr,
) -> Result<(), FileError> {
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
            Ok(Some(status)) if status.success() => return Ok(()),
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


/// Metadata of the entry at a path, never following a symbolic link.
pub fn stat(path: &str, cancel: &AtomicBool) -> Result<Metadata, FileError> {
    let parts = path_parts(path)?;
    let (name, parents) = parts
        .split_last()
        .ok_or_else(|| FileError::InvalidPath(path.into()))?;
    let parent = directory(parents, path, cancel)?;
    let stat = stat_at(parent.as_raw_fd(), name, path)?;
    Ok(Metadata {
        kind: kind(stat.st_mode),
        size: stat.st_size as u64,
        device: stat.st_dev as u64,
        inode: stat.st_ino as u64,
    })
}

/// Reads at most `max` bytes of a regular file from `offset`, with the size
/// the file reported when it was opened.
pub fn read_at(
    path: &str,
    offset: u64,
    max: usize,
    cancel: &AtomicBool,
) -> Result<(Vec<u8>, u64), FileError> {
    let (mut file, stat) = regular_file(path, cancel)?;
    let size = stat.st_size as u64;
    if offset >= size {
        return Ok((Vec::new(), size));
    }
    file.seek(SeekFrom::Start(offset))
        .map_err(|error| io_error(path, error))?;
    let count = max.min((size - offset).min(usize::MAX as u64) as usize);
    let bytes = read_chunk(&mut file, path, cancel, count, io_error)?;
    Ok((bytes, size))
}

/// Creates or replaces a regular file with the bytes. The destination is
/// opened without following a symbolic link and refused unless it is, or
/// becomes, a regular file.
pub fn write_bytes(path: &str, bytes: &[u8], cancel: &AtomicBool) -> Result<(), FileError> {
    let parts = path_parts(path)?;
    let (name, parents) = parts
        .split_last()
        .ok_or_else(|| FileError::InvalidPath(path.into()))?;
    let parent = directory(parents, path, cancel)?;
    let mut file = open_at(
        parent.as_raw_fd(),
        name,
        libc::O_WRONLY | libc::O_CREAT | libc::O_NONBLOCK,
        0o600,
        path,
    )?;
    let stat = file_stat(&file, path)?;
    if kind(stat.st_mode) != Kind::File {
        return Err(FileError::InvalidPath(path.into()));
    }
    file.set_len(0).map_err(|error| io_error(path, error))?;
    for chunk in bytes.chunks(CHUNK_BYTES) {
        canceled(cancel)?;
        file.write_all(chunk)
            .map_err(|error| io_error(path, error))?;
    }
    Ok(())
}

/// Renames an entry, replacing a regular file at the destination. The rename
/// replaces the directory entry itself, never a symbolic link's target.
pub fn rename(from: &str, to: &str, cancel: &AtomicBool) -> Result<(), FileError> {
    let from_parts = path_parts(from)?;
    let (from_name, from_parents) = from_parts
        .split_last()
        .ok_or_else(|| FileError::InvalidPath(from.into()))?;
    let to_parts = path_parts(to)?;
    let (to_name, to_parents) = to_parts
        .split_last()
        .ok_or_else(|| FileError::InvalidPath(to.into()))?;
    let from_dir = directory(from_parents, from, cancel)?;
    let to_dir = directory(to_parents, to, cancel)?;
    match stat_at(to_dir.as_raw_fd(), to_name, to) {
        Ok(stat) if kind(stat.st_mode) != Kind::File => {
            return Err(FileError::InvalidPath(to.into()));
        }
        Ok(_) | Err(FileError::NotFound(_)) => {}
        Err(error) => return Err(error),
    }
    let from_c = name_cstring(from_name, from)?;
    let to_c = name_cstring(to_name, to)?;
    canceled(cancel)?;
    // SAFETY: both names are valid, relative to live directory descriptors.
    if unsafe {
        libc::renameat(
            from_dir.as_raw_fd(),
            from_c.as_ptr(),
            to_dir.as_raw_fd(),
            to_c.as_ptr(),
        )
    } < 0
    {
        return Err(io_error(from, io::Error::last_os_error()));
    }
    Ok(())
}

/// Removes a regular file, a symbolic link itself, or an empty directory.
pub fn remove(path: &str, cancel: &AtomicBool) -> Result<(), FileError> {
    let parts = path_parts(path)?;
    let (name, parents) = parts
        .split_last()
        .ok_or_else(|| FileError::InvalidPath(path.into()))?;
    let parent = directory(parents, path, cancel)?;
    let stat = stat_at(parent.as_raw_fd(), name, path)?;
    let flags = if kind(stat.st_mode) == Kind::Directory {
        libc::AT_REMOVEDIR
    } else {
        0
    };
    let name = name_cstring(name, path)?;
    // SAFETY: the name is valid and relative to a live directory descriptor.
    if unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), flags) } < 0 {
        return Err(io_error(path, io::Error::last_os_error()));
    }
    Ok(())
}

/// Flushes a regular file's contents and metadata to durable storage.
pub fn sync(path: &str, cancel: &AtomicBool) -> Result<(), FileError> {
    let (file, _) = regular_file(path, cancel)?;
    file.sync_all().map_err(|error| io_error(path, error))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn sandbox(name: &str) -> String {
        let dir = std::env::temp_dir().join(format!(
            "roc-signals-files-{}-{name}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir.to_str().unwrap().to_owned()
    }

    #[test]
    fn primitives_round_trip_a_file_and_refuse_symlinks() {
        let cancel = AtomicBool::new(false);
        let dir = sandbox("primitives");
        let path = format!("{dir}/note.txt");
        write_bytes(&path, "hello λ".as_bytes(), &cancel).unwrap();
        let meta = stat(&path, &cancel).unwrap();
        assert_eq!((meta.kind, meta.size), (Kind::File, 8));
        let (bytes, size) = read_at(&path, 6, 10, &cancel).unwrap();
        assert_eq!((bytes.as_slice(), size), ("λ".as_bytes(), 8));
        let (past_end, _) = read_at(&path, 99, 10, &cancel).unwrap();
        assert!(past_end.is_empty());
        sync(&path, &cancel).unwrap();
        let moved = format!("{dir}/moved.txt");
        rename(&path, &moved, &cancel).unwrap();
        assert!(matches!(stat(&path, &cancel), Err(FileError::NotFound(_))));
        let link = format!("{dir}/link.txt");
        symlink(&moved, &link).unwrap();
        assert_eq!(stat(&link, &cancel).unwrap().kind, Kind::SymbolicLink);
        assert!(matches!(read_at(&link, 0, 10, &cancel), Err(FileError::InvalidPath(_))));
        assert!(matches!(write_bytes(&link, b"x", &cancel), Err(FileError::InvalidPath(_))));
        remove(&link, &cancel).unwrap();
        assert_eq!(std::fs::read(&moved).unwrap(), "hello λ".as_bytes());
        remove(&moved, &cancel).unwrap();
        remove(&dir, &cancel).unwrap();
        assert!(matches!(stat(&dir, &cancel), Err(FileError::NotFound(_))));
    }

    #[test]
    fn rename_refuses_replacing_a_directory_and_listing_stays_sorted() {
        let cancel = AtomicBool::new(false);
        let dir = sandbox("rename");
        let file = format!("{dir}/b.txt");
        write_bytes(&file, b"b", &cancel).unwrap();
        std::fs::create_dir(format!("{dir}/a")).unwrap();
        assert!(matches!(
            rename(&file, &format!("{dir}/a"), &cancel),
            Err(FileError::InvalidPath(_))
        ));
        let listing = list_directory(&dir, &cancel).unwrap();
        let names: Vec<&str> = listing.entries.iter().map(|entry| entry.path.as_str()).collect();
        assert_eq!(names, vec![format!("{dir}/a").as_str(), file.as_str()]);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
