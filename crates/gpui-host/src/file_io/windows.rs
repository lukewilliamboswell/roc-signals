//! Bounded Windows file primitives for scope-owned worker requests.
//!
//! Every path component is opened relative to an owned directory handle through
//! `NtCreateFile` with `FILE_OPEN_REPARSE_POINT`, so a symbolic link, junction,
//! or other reparse point is opened as itself and then refused instead of
//! being followed. A renamed directory remains the same opened directory.
//! Replacement goes through a same-directory temporary and a handle-relative
//! `FileRenameInfoEx` rename, which needs Windows 10 version 1607 or later.
use super::{
    CHUNK_BYTES, DirectoryListing, Entry, FileError, Kind, MAX_PATH_BYTES, MAX_SCAN_DEPTH,
    MAX_SCAN_ENTRIES, MAX_SCAN_PATH_BYTES, Metadata, bounded_detail, canceled, read_chunk,
};
use std::{
    ffi::{OsStr, c_void},
    fs::File,
    io::{self, Seek, SeekFrom, Write},
    os::windows::{
        ffi::OsStrExt,
        io::{AsRawHandle, FromRawHandle, OwnedHandle},
    },
    path::{Component, Path, Prefix},
    sync::atomic::{AtomicBool, Ordering},
};
use windows_sys::{
    Wdk::{
        Foundation::OBJECT_ATTRIBUTES,
        Storage::FileSystem::{
            FILE_DIRECTORY_FILE, FILE_DISPOSITION_DELETE,
            FILE_DISPOSITION_INFORMATION_EX, FILE_DISPOSITION_POSIX_SEMANTICS,
            FILE_NON_DIRECTORY_FILE, FILE_OPEN, FILE_OPEN_IF, FILE_OPEN_REPARSE_POINT, FILE_RENAME_INFORMATION,
            FILE_RENAME_POSIX_SEMANTICS, FILE_RENAME_REPLACE_IF_EXISTS,
            FILE_SYNCHRONOUS_IO_NONALERT, FileDispositionInformationEx, FileRenameInformationEx,
            NtCreateFile, NtSetInformationFile,
        },
    },
    Win32::{
        Foundation::{
            ERROR_ACCESS_DENIED, ERROR_BAD_NETPATH, ERROR_BAD_PATHNAME,
            ERROR_CANT_ACCESS_FILE, ERROR_CANT_RESOLVE_FILENAME, ERROR_DIRECTORY,
            ERROR_DIRECTORY_NOT_SUPPORTED, ERROR_DISK_FULL,
            ERROR_FILE_NOT_FOUND, ERROR_FILENAME_EXCED_RANGE, ERROR_HANDLE_DISK_FULL,
            ERROR_INVALID_NAME, ERROR_INVALID_PARAMETER, ERROR_NO_MORE_FILES,
            ERROR_NOT_ENOUGH_MEMORY, ERROR_OUTOFMEMORY, ERROR_PATH_NOT_FOUND,
            ERROR_SHARING_VIOLATION, ERROR_TOO_MANY_OPEN_FILES, HANDLE, NTSTATUS,
            OBJ_CASE_INSENSITIVE, RtlNtStatusToDosError, UNICODE_STRING,
        },
        Storage::FileSystem::{
            DELETE, FILE_ATTRIBUTE_DEVICE, FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_NORMAL,
            FILE_ATTRIBUTE_REPARSE_POINT, FILE_ATTRIBUTE_TAG_INFO,
            FILE_ID_EXTD_DIR_INFO, FILE_ID_INFO, FILE_LIST_DIRECTORY, FILE_READ_ATTRIBUTES,
            FILE_READ_DATA, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
            FILE_STANDARD_INFO, FILE_WRITE_ATTRIBUTES, FILE_WRITE_DATA, FileAttributeTagInfo,
            FileIdExtdDirectoryInfo, FileIdExtdDirectoryRestartInfo, FileIdInfo,
            FileStandardInfo, GetFileInformationByHandleEx, SYNCHRONIZE,
        },
        System::IO::IO_STATUS_BLOCK,
    },
};

const LISTING_BYTES: usize = 64 * 1024;
const DIRECTORY_ACCESS: u32 = FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE;
const SHARE_ALL: u32 = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;

fn win32_error(path: &str, error: io::Error) -> FileError {
    let message = bounded_detail(format!("{path}: {error}"));
    match error.raw_os_error().map(|code| code as u32) {
        Some(ERROR_FILE_NOT_FOUND | ERROR_PATH_NOT_FOUND | ERROR_BAD_NETPATH) => {
            FileError::NotFound(message)
        }
        Some(ERROR_ACCESS_DENIED | ERROR_SHARING_VIOLATION) => FileError::PermissionDenied(message),
        Some(
            ERROR_INVALID_NAME
            | ERROR_BAD_PATHNAME
            | ERROR_DIRECTORY
            | ERROR_DIRECTORY_NOT_SUPPORTED
            | ERROR_FILENAME_EXCED_RANGE
            | ERROR_INVALID_PARAMETER
            | ERROR_CANT_ACCESS_FILE
            | ERROR_CANT_RESOLVE_FILENAME,
        ) => FileError::InvalidPath(message),
        Some(
            ERROR_NOT_ENOUGH_MEMORY
            | ERROR_OUTOFMEMORY
            | ERROR_TOO_MANY_OPEN_FILES
            | ERROR_DISK_FULL
            | ERROR_HANDLE_DISK_FULL,
        ) => FileError::ResourceLimit(message),
        _ => FileError::Io(message),
    }
}

const STATUS_FILE_IS_A_DIRECTORY: NTSTATUS = 0xC00000BA_u32 as NTSTATUS;

fn status_error(status: NTSTATUS) -> io::Error {
    // Win32 folds "is a directory" into ERROR_ACCESS_DENIED, which would report
    // a directory path as a permission problem instead of an invalid path.
    if status == STATUS_FILE_IS_A_DIRECTORY {
        return io::Error::from_raw_os_error(ERROR_DIRECTORY_NOT_SUPPORTED as i32);
    }
    // SAFETY: pure translation of a status code; no memory is involved.
    io::Error::from_raw_os_error(unsafe { RtlNtStatusToDosError(status) } as i32)
}

/// Splits an absolute drive path into its NT volume root and plain components.
/// Relative, `..`, device, UNC, and NUL-containing paths are refused so the
/// walk below only ever opens names relative to an already owned directory.
fn path_parts(path: &str) -> Result<(String, Vec<&OsStr>), FileError> {
    if path.len() > MAX_PATH_BYTES {
        return Err(FileError::InvalidPath(
            "path exceeds 4096 UTF-8 bytes".into(),
        ));
    }
    if path.as_bytes().contains(&0) || !Path::new(path).is_absolute() {
        return Err(FileError::InvalidPath(path.into()));
    }
    let mut components = Path::new(path).components();
    let drive = match components.next() {
        Some(Component::Prefix(prefix)) => match prefix.kind() {
            Prefix::Disk(letter) | Prefix::VerbatimDisk(letter) => letter,
            _ => return Err(FileError::InvalidPath(path.into())),
        },
        _ => return Err(FileError::InvalidPath(path.into())),
    };
    let parts = components
        .filter_map(|part| match part {
            Component::RootDir | Component::CurDir => None,
            Component::Normal(name) => Some(Ok(name)),
            _ => Some(Err(FileError::InvalidPath(path.into()))),
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok((
        format!("\\??\\{}:\\", drive.to_ascii_uppercase() as char),
        parts,
    ))
}

fn unicode(name: &[u16]) -> UNICODE_STRING {
    let bytes = name.len() * 2;
    UNICODE_STRING {
        Length: bytes as u16,
        MaximumLength: bytes as u16,
        Buffer: name.as_ptr().cast_mut(),
    }
}

fn name_units(name: &OsStr, path: &str) -> Result<Vec<u16>, FileError> {
    let units: Vec<u16> = name.encode_wide().collect();
    if units.is_empty() || units.len() * 2 > u16::MAX as usize || units.contains(&0) {
        return Err(FileError::InvalidPath(path.into()));
    }
    Ok(units)
}

/// Opens one name relative to `parent` (or a `\??\` volume root when `parent`
/// is null) without following reparse points. Ownership of the handle passes
/// to the caller exactly once, on success.
fn open_at(
    parent: HANDLE,
    name: &[u16],
    access: u32,
    disposition: u32,
    options: u32,
    attributes: u32,
    path: &str,
) -> Result<OwnedHandle, FileError> {
    nt_open(parent, name, access, disposition, options, attributes)
        .map_err(|error| win32_error(path, error))
}

fn nt_open(
    parent: HANDLE,
    name: &[u16],
    access: u32,
    disposition: u32,
    options: u32,
    attributes: u32,
) -> io::Result<OwnedHandle> {
    let object_name = unicode(name);
    let attributes_block = OBJECT_ATTRIBUTES {
        Length: std::mem::size_of::<OBJECT_ATTRIBUTES>() as u32,
        RootDirectory: parent,
        ObjectName: &object_name,
        Attributes: OBJ_CASE_INSENSITIVE,
        SecurityDescriptor: std::ptr::null(),
        SecurityQualityOfService: std::ptr::null(),
    };
    let mut handle: HANDLE = std::ptr::null_mut();
    let mut status_block = IO_STATUS_BLOCK::default();
    // SAFETY: every pointer refers to live stack data for the duration of the
    // call, the caller keeps `parent` open, and a successful call yields one
    // fresh handle that OwnedHandle closes exactly once.
    let status = unsafe {
        NtCreateFile(
            &mut handle,
            access,
            &attributes_block,
            &mut status_block,
            std::ptr::null(),
            attributes,
            SHARE_ALL,
            disposition,
            options | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
            std::ptr::null(),
            0,
        )
    };
    if status < 0 {
        return Err(status_error(status));
    }
    Ok(unsafe { OwnedHandle::from_raw_handle(handle) })
}

fn query<T>(handle: HANDLE, class: i32, path: &str) -> Result<T, FileError> {
    let mut info = std::mem::MaybeUninit::<T>::uninit();
    // SAFETY: the output buffer is exactly one T and the handle is live.
    if unsafe {
        GetFileInformationByHandleEx(
            handle,
            class,
            info.as_mut_ptr().cast(),
            std::mem::size_of::<T>() as u32,
        )
    } == 0
    {
        return Err(win32_error(path, io::Error::last_os_error()));
    }
    Ok(unsafe { info.assume_init() })
}

fn kind(attributes: u32) -> Kind {
    if attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        Kind::SymbolicLink
    } else if attributes & FILE_ATTRIBUTE_DIRECTORY != 0 {
        Kind::Directory
    } else if attributes & FILE_ATTRIBUTE_DEVICE != 0 {
        Kind::Other
    } else {
        Kind::File
    }
}

struct Stat {
    attributes: u32,
    size: i64,
    id: Identity,
}

#[derive(PartialEq, Eq)]
struct Identity {
    volume: u64,
    file: [u8; 16],
}

fn handle_stat(handle: &OwnedHandle, path: &str) -> Result<Stat, FileError> {
    let raw = handle.as_raw_handle();
    let tag: FILE_ATTRIBUTE_TAG_INFO = query(raw, FileAttributeTagInfo, path)?;
    let standard: FILE_STANDARD_INFO = query(raw, FileStandardInfo, path)?;
    let id: FILE_ID_INFO = query(raw, FileIdInfo, path)?;
    Ok(Stat {
        attributes: tag.FileAttributes,
        size: standard.EndOfFile,
        id: Identity {
            volume: id.VolumeSerialNumber,
            file: id.FileId.Identifier,
        },
    })
}

/// Opens a directory chain from the volume root, refusing any component that
/// is a reparse point. The returned handle is the final directory itself.
fn directory(
    root: &str,
    parts: &[&OsStr],
    path: &str,
    cancel: &AtomicBool,
) -> Result<OwnedHandle, FileError> {
    canceled(cancel)?;
    let root_units: Vec<u16> = OsStr::new(root).encode_wide().collect();
    let mut current = open_at(
        std::ptr::null_mut(),
        &root_units,
        DIRECTORY_ACCESS,
        FILE_OPEN,
        FILE_DIRECTORY_FILE,
        0,
        path,
    )?;
    for part in parts {
        canceled(cancel)?;
        let name = name_units(part, path)?;
        current = open_at(
            current.as_raw_handle(),
            &name,
            DIRECTORY_ACCESS,
            FILE_OPEN,
            FILE_DIRECTORY_FILE,
            0,
            path,
        )?;
        if handle_stat(&current, path)?.attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return Err(FileError::InvalidPath(bounded_detail(format!(
                "{path}: reparse point in directory path"
            ))));
        }
    }
    Ok(current)
}

/// Opens one regular file through no-follow handles, refusing reparse points
/// (including parent components), directories, and devices.
fn regular_file(path: &str, cancel: &AtomicBool) -> Result<(File, Stat), FileError> {
    let (root, parts) = path_parts(path)?;
    let (name, parents) = parts
        .split_last()
        .ok_or_else(|| FileError::InvalidPath(path.into()))?;
    let parent = directory(&root, parents, path, cancel)?;
    let name = name_units(name, path)?;
    let handle = open_at(
        parent.as_raw_handle(),
        &name,
        FILE_READ_DATA | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
        FILE_OPEN,
        FILE_NON_DIRECTORY_FILE,
        0,
        path,
    )?;
    let stat = handle_stat(&handle, path)?;
    if kind(stat.attributes) != Kind::File {
        return Err(FileError::InvalidPath(path.into()));
    }
    Ok((File::from(handle), stat))
}






fn set_information(
    handle: HANDLE,
    class: i32,
    block: *const c_void,
    length: usize,
) -> io::Result<()> {
    let mut status_block = IO_STATUS_BLOCK::default();
    // SAFETY: the caller passes a block of exactly `length` readable bytes laid
    // out as `class` expects, and keeps the handle open for the call.
    let status =
        unsafe { NtSetInformationFile(handle, &mut status_block, block, length as u32, class) };
    if status < 0 {
        return Err(status_error(status));
    }
    Ok(())
}

/// Renames the open temporary over `destination` in the same directory. The
/// rename replaces the directory entry itself, never a reparse target, and the
/// destination handle stays the parent directory that was already validated.
fn rename_over(
    file: &File,
    parent: HANDLE,
    destination: &[u16],
    path: &str,
) -> Result<(), FileError> {
    let name_bytes = destination.len() * 2;
    let header = std::mem::offset_of!(FILE_RENAME_INFORMATION, FileName);
    let mut buffer =
        vec![0u8; std::mem::size_of::<FILE_RENAME_INFORMATION>().max(header + name_bytes)];
    // SAFETY: the buffer covers the fixed header followed by the UTF-16 name and
    // every write stays within it; the header is written in place.
    unsafe {
        let info = buffer.as_mut_ptr().cast::<FILE_RENAME_INFORMATION>();
        (*info).Anonymous.Flags = FILE_RENAME_REPLACE_IF_EXISTS | FILE_RENAME_POSIX_SEMANTICS;
        (*info).RootDirectory = parent;
        (*info).FileNameLength = name_bytes as u32;
        std::ptr::copy_nonoverlapping(
            destination.as_ptr().cast::<u8>(),
            buffer.as_mut_ptr().add(header),
            name_bytes,
        );
    }
    set_information(
        file.as_raw_handle(),
        FileRenameInformationEx,
        buffer.as_ptr().cast::<c_void>(),
        buffer.len(),
    )
    .map_err(|error| win32_error(path, error))
}

struct ScanBudget {
    entries: Vec<Entry>,
    path_bytes: usize,
}

struct Listed {
    name: String,
    attributes: u32,
    size: i64,
    id: [u8; 16],
}

/// Reads the complete directory listing through the handle's own enumeration
/// state. The names come back as UTF-16; any name that is not valid Unicode
/// refuses the scan just as a non-UTF-8 name does elsewhere.
fn list_entries(
    directory: &OwnedHandle,
    path: &str,
    cancel: &AtomicBool,
) -> Result<Vec<Listed>, FileError> {
    let mut listed = Vec::new();
    let mut buffer = vec![0u8; LISTING_BYTES];
    let mut class = FileIdExtdDirectoryRestartInfo;
    loop {
        canceled(cancel)?;
        // SAFETY: the buffer is writable for its whole length and the handle is live.
        let ok = unsafe {
            GetFileInformationByHandleEx(
                directory.as_raw_handle(),
                class,
                buffer.as_mut_ptr().cast(),
                buffer.len() as u32,
            )
        };
        if ok == 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(ERROR_NO_MORE_FILES as i32) {
                return Ok(listed);
            }
            return Err(win32_error(path, error));
        }
        class = FileIdExtdDirectoryInfo;
        let mut offset = 0usize;
        loop {
            // SAFETY: the kernel wrote a chain of FILE_ID_EXTD_DIR_INFO records
            // starting at offset 0; each NextEntryOffset stays inside the buffer.
            let entry = unsafe { &*buffer.as_ptr().add(offset).cast::<FILE_ID_EXTD_DIR_INFO>() };
            let name_offset = offset + std::mem::offset_of!(FILE_ID_EXTD_DIR_INFO, FileName);
            let name_len = entry.FileNameLength as usize;
            if name_offset + name_len > buffer.len() {
                return Err(FileError::Io(bounded_detail(format!(
                    "{path}: directory listing exceeded its buffer"
                ))));
            }
            let units: Vec<u16> = buffer[name_offset..name_offset + name_len]
                .chunks_exact(2)
                .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
                .collect();
            let name =
                String::from_utf16(&units).map_err(|_| FileError::InvalidUtf8(path.into()))?;
            listed
                .try_reserve(1)
                .map_err(|_| FileError::ResourceLimit(path.into()))?;
            listed.push(Listed {
                name,
                attributes: entry.FileAttributes,
                size: entry.EndOfFile,
                id: entry.FileId.Identifier,
            });
            if entry.NextEntryOffset == 0 {
                break;
            }
            offset += entry.NextEntryOffset as usize;
        }
    }
}

fn scan_directory(
    directory: &OwnedHandle,
    path: &str,
    depth: usize,
    cancel: &AtomicBool,
    budget: &mut ScanBudget,
    recursive: bool,
) -> Result<(), FileError> {
    canceled(cancel)?;
    let separator = if path.contains('/') && !path.contains('\\') {
        '/'
    } else {
        '\\'
    };
    for entry in list_entries(directory, path, cancel)? {
        canceled(cancel)?;
        if entry.name == "." || entry.name == ".." {
            continue;
        }
        let entry_path = format!(
            "{}{separator}{}",
            path.trim_end_matches(['\\', '/']),
            entry.name
        );
        if entry_path.len() > MAX_PATH_BYTES
            || budget.entries.len() == MAX_SCAN_ENTRIES
            || budget.path_bytes + entry_path.len() > MAX_SCAN_PATH_BYTES
        {
            return Err(FileError::ResourceLimit(path.into()));
        }
        let entry_kind = kind(entry.attributes);
        budget
            .entries
            .try_reserve(1)
            .map_err(|_| FileError::ResourceLimit(path.into()))?;
        budget.path_bytes += entry_path.len();
        budget.entries.push(Entry {
            path: entry_path.clone(),
            kind: entry_kind,
            bytes: entry.size.max(0) as u64,
        });
        if recursive && entry_kind == Kind::Directory {
            if depth == MAX_SCAN_DEPTH {
                return Err(FileError::ResourceLimit(path.into()));
            }
            let name = name_units(OsStr::new(&entry.name), &entry_path)?;
            let child = open_at(
                directory.as_raw_handle(),
                &name,
                DIRECTORY_ACCESS,
                FILE_OPEN,
                FILE_DIRECTORY_FILE,
                0,
                &entry_path,
            )?;
            let opened = handle_stat(&child, &entry_path)?;
            let parent_volume = handle_stat(directory, path)?.id.volume;
            if opened.id
                != (Identity {
                    volume: parent_volume,
                    file: entry.id,
                })
                || opened.attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0
            {
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
/// reparse points are metadata entries and are never followed. Results are
/// path-sorted.
pub fn list_directory(path: &str, cancel: &AtomicBool) -> Result<DirectoryListing, FileError> {
    let (volume, parts) = path_parts(path)?;
    let directory = directory(&volume, &parts, path, cancel)?;
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


/// The opaque log cursor identity: the volume serial and the low 64 bits of
/// the 128-bit file identifier, which is the complete identifier on NTFS.
fn log_identity(stat: &Stat) -> (u64, u64) {
    let mut low = [0u8; 8];
    low.copy_from_slice(&stat.id.file[..8]);
    (stat.id.volume, u64::from_le_bytes(low))
}


/// Requests the shell's associated application through the file protocol
/// handler that ships with Windows. Success means the shell accepted the
/// launch; it does not own the resulting application. Cancellation/deadline
/// kills and reaps the launcher but cannot undo a launch already handed off.
/// The path is validated through no-follow handles first; the external
/// application subsequently resolves that path and owns its own access policy.
/// Launcher stdout/stderr are never retained.
pub fn open_path(path: &str, cancel: &AtomicBool) -> Result<(), FileError> {
    open_path_with_launcher(
        path,
        cancel,
        OsStr::new("rundll32.exe"),
        &[OsStr::new("url.dll,FileProtocolHandler")],
    )
}

fn open_path_with_launcher(
    path: &str,
    cancel: &AtomicBool,
    launcher: &OsStr,
    arguments: &[&OsStr],
) -> Result<(), FileError> {
    use std::{
        process::{Command, Stdio},
        time::{Duration, Instant},
    };
    let (_file, _) = regular_file(path, cancel)?;
    canceled(cancel)?;
    let mut child = Command::new(launcher)
        .args(arguments)
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


/// Metadata of the entry at a path, never following a reparse point.
pub fn stat(path: &str, cancel: &AtomicBool) -> Result<Metadata, FileError> {
    let (root, parts) = path_parts(path)?;
    let (name, parents) = parts
        .split_last()
        .ok_or_else(|| FileError::InvalidPath(path.into()))?;
    let parent = directory(&root, parents, path, cancel)?;
    let name = name_units(name, path)?;
    let handle = open_at(
        parent.as_raw_handle(),
        &name,
        FILE_READ_ATTRIBUTES | SYNCHRONIZE,
        FILE_OPEN,
        0,
        0,
        path,
    )?;
    let stat = handle_stat(&handle, path)?;
    let (device, inode) = log_identity(&stat);
    Ok(Metadata {
        kind: kind(stat.attributes),
        size: stat.size.max(0) as u64,
        device,
        inode,
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
    let size = stat.size.max(0) as u64;
    if offset >= size {
        return Ok((Vec::new(), size));
    }
    file.seek(SeekFrom::Start(offset))
        .map_err(|error| win32_error(path, error))?;
    let count = max.min((size - offset).min(usize::MAX as u64) as usize);
    let bytes = read_chunk(&mut file, path, cancel, count, win32_error)?;
    Ok((bytes, size))
}

/// Creates or replaces a regular file with the bytes, refusing reparse points
/// and devices at the destination.
pub fn write_bytes(path: &str, bytes: &[u8], cancel: &AtomicBool) -> Result<(), FileError> {
    let (root, parts) = path_parts(path)?;
    let (name, parents) = parts
        .split_last()
        .ok_or_else(|| FileError::InvalidPath(path.into()))?;
    let parent = directory(&root, parents, path, cancel)?;
    let name = name_units(name, path)?;
    let handle = open_at(
        parent.as_raw_handle(),
        &name,
        FILE_WRITE_DATA | FILE_WRITE_ATTRIBUTES | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
        FILE_OPEN_IF,
        FILE_NON_DIRECTORY_FILE,
        FILE_ATTRIBUTE_NORMAL,
        path,
    )?;
    let stat = handle_stat(&handle, path)?;
    if kind(stat.attributes) != Kind::File {
        return Err(FileError::InvalidPath(path.into()));
    }
    let mut file = File::from(handle);
    file.set_len(0).map_err(|error| win32_error(path, error))?;
    for chunk in bytes.chunks(CHUNK_BYTES) {
        canceled(cancel)?;
        file.write_all(chunk)
            .map_err(|error| win32_error(path, error))?;
    }
    Ok(())
}

/// Renames an entry, replacing a regular file at the destination through a
/// handle-relative rename that never follows a reparse point.
pub fn rename(from: &str, to: &str, cancel: &AtomicBool) -> Result<(), FileError> {
    let (from_root, from_parts) = path_parts(from)?;
    let (from_name, from_parents) = from_parts
        .split_last()
        .ok_or_else(|| FileError::InvalidPath(from.into()))?;
    let (to_root, to_parts) = path_parts(to)?;
    let (to_name, to_parents) = to_parts
        .split_last()
        .ok_or_else(|| FileError::InvalidPath(to.into()))?;
    let from_dir = directory(&from_root, from_parents, from, cancel)?;
    let to_dir = directory(&to_root, to_parents, to, cancel)?;
    let to_units = name_units(to_name, to)?;
    match open_at(
        to_dir.as_raw_handle(),
        &to_units,
        FILE_READ_ATTRIBUTES | SYNCHRONIZE,
        FILE_OPEN,
        0,
        0,
        to,
    ) {
        Ok(existing) => {
            if kind(handle_stat(&existing, to)?.attributes) != Kind::File {
                return Err(FileError::InvalidPath(to.into()));
            }
        }
        Err(FileError::NotFound(_)) => {}
        Err(error) => return Err(error),
    }
    let source = open_at(
        from_dir.as_raw_handle(),
        &name_units(from_name, from)?,
        DELETE | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
        FILE_OPEN,
        0,
        0,
        from,
    )?;
    canceled(cancel)?;
    rename_over(&File::from(source), to_dir.as_raw_handle(), &to_units, from)
}

/// Removes a regular file, a reparse point itself, or an empty directory.
pub fn remove(path: &str, cancel: &AtomicBool) -> Result<(), FileError> {
    let (root, parts) = path_parts(path)?;
    let (name, parents) = parts
        .split_last()
        .ok_or_else(|| FileError::InvalidPath(path.into()))?;
    let parent = directory(&root, parents, path, cancel)?;
    let handle = open_at(
        parent.as_raw_handle(),
        &name_units(name, path)?,
        DELETE | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
        FILE_OPEN,
        0,
        0,
        path,
    )?;
    let disposition = FILE_DISPOSITION_INFORMATION_EX {
        Flags: FILE_DISPOSITION_DELETE | FILE_DISPOSITION_POSIX_SEMANTICS,
    };
    set_information(
        handle.as_raw_handle(),
        FileDispositionInformationEx,
        (&raw const disposition).cast(),
        std::mem::size_of::<FILE_DISPOSITION_INFORMATION_EX>(),
    )
    .map_err(|error| win32_error(path, error))
}

/// Flushes a regular file's contents and metadata to durable storage.
pub fn sync(path: &str, cancel: &AtomicBool) -> Result<(), FileError> {
    let (root, parts) = path_parts(path)?;
    let (name, parents) = parts
        .split_last()
        .ok_or_else(|| FileError::InvalidPath(path.into()))?;
    let parent = directory(&root, parents, path, cancel)?;
    let handle = open_at(
        parent.as_raw_handle(),
        &name_units(name, path)?,
        FILE_WRITE_DATA | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
        FILE_OPEN,
        FILE_NON_DIRECTORY_FILE,
        0,
        path,
    )?;
    if kind(handle_stat(&handle, path)?.attributes) != Kind::File {
        return Err(FileError::InvalidPath(path.into()));
    }
    File::from(handle)
        .sync_all()
        .map_err(|error| win32_error(path, error))
}
