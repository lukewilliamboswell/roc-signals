//! Bounded Windows file primitives for scope-owned worker requests.
//!
//! Every path component is opened relative to an owned directory handle through
//! `NtCreateFile` with `FILE_OPEN_REPARSE_POINT`, so a symbolic link, junction,
//! or other reparse point is opened as itself and then refused instead of
//! being followed. A renamed directory remains the same opened directory.
//! Replacement goes through a same-directory temporary and a handle-relative
//! `FileRenameInfoEx` rename, which needs Windows 10 version 1607 or later.
use super::{
    CHUNK_BYTES, DirectoryListing, Entry, FileError, Kind, LogChange, LogChunk, LogCursor,
    LogPosition, LogState, MAX_CHUNK_BYTES, MAX_PATH_BYTES, MAX_SCAN_DEPTH, MAX_SCAN_ENTRIES,
    MAX_SCAN_PATH_BYTES, MAX_TEXT_BYTES, Opened, Preview, Scan, TEMP_SERIAL, TextFile, Written,
    bounded_detail, canceled, read_chunk, utf8_prefix,
};
use std::{
    ffi::{OsStr, c_void},
    fs::File,
    io::{self, Read, Seek, SeekFrom, Write},
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
            FILE_CREATE, FILE_DIRECTORY_FILE, FILE_DISPOSITION_DELETE,
            FILE_DISPOSITION_INFORMATION_EX, FILE_DISPOSITION_POSIX_SEMANTICS,
            FILE_NON_DIRECTORY_FILE, FILE_OPEN, FILE_OPEN_REPARSE_POINT, FILE_RENAME_INFORMATION,
            FILE_RENAME_POSIX_SEMANTICS, FILE_RENAME_REPLACE_IF_EXISTS,
            FILE_SYNCHRONOUS_IO_NONALERT, FileDispositionInformationEx, FileRenameInformationEx,
            NtCreateFile, NtSetInformationFile,
        },
    },
    Win32::{
        Foundation::{
            ERROR_ACCESS_DENIED, ERROR_ALREADY_EXISTS, ERROR_BAD_NETPATH, ERROR_BAD_PATHNAME,
            ERROR_CANT_ACCESS_FILE, ERROR_CANT_RESOLVE_FILENAME, ERROR_DIRECTORY,
            ERROR_DIRECTORY_NOT_SUPPORTED, ERROR_DISK_FULL, ERROR_FILE_EXISTS,
            ERROR_FILE_NOT_FOUND, ERROR_FILENAME_EXCED_RANGE, ERROR_HANDLE_DISK_FULL,
            ERROR_INVALID_NAME, ERROR_INVALID_PARAMETER, ERROR_NO_MORE_FILES,
            ERROR_NOT_ENOUGH_MEMORY, ERROR_OUTOFMEMORY, ERROR_PATH_NOT_FOUND,
            ERROR_SHARING_VIOLATION, ERROR_TOO_MANY_OPEN_FILES, HANDLE, NTSTATUS,
            OBJ_CASE_INSENSITIVE, RtlNtStatusToDosError, UNICODE_STRING,
        },
        Storage::FileSystem::{
            DELETE, FILE_ATTRIBUTE_DEVICE, FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_NORMAL,
            FILE_ATTRIBUTE_REPARSE_POINT, FILE_ATTRIBUTE_TAG_INFO, FILE_BASIC_INFO,
            FILE_ID_EXTD_DIR_INFO, FILE_ID_INFO, FILE_LIST_DIRECTORY, FILE_READ_ATTRIBUTES,
            FILE_READ_DATA, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
            FILE_STANDARD_INFO, FILE_WRITE_ATTRIBUTES, FILE_WRITE_DATA, FileAttributeTagInfo,
            FileBasicInfo, FileIdExtdDirectoryInfo, FileIdExtdDirectoryRestartInfo, FileIdInfo,
            FileStandardInfo, GetFileInformationByHandleEx, SYNCHRONIZE,
            SetFileInformationByHandle,
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

/// Reads one regular UTF-8 file, checking cancellation between bounded chunks.
/// Reparse points (including parent components) and devices are refused.
/// Reads one regular file's complete bytes up to the caller's bound, checking
/// cancellation between chunks. Symbolic links (including parent components)
/// and special files are refused exactly like read_text.
pub fn read_bytes(path: &str, cancel: &AtomicBool, max: usize) -> Result<Vec<u8>, FileError> {
    let (mut file, stat) = regular_file(path, cancel)?;
    if stat.size > max as i64 {
        return Err(FileError::ResourceLimit(path.into()));
    }
    let mut bytes = Vec::new();
    let mut chunk = [0u8; CHUNK_BYTES];
    loop {
        canceled(cancel)?;
        let count = file
            .read(&mut chunk)
            .map_err(|error| win32_error(path, error))?;
        if count == 0 {
            break;
        }
        if bytes.len() + count > max {
            return Err(FileError::ResourceLimit(path.into()));
        }
        bytes
            .try_reserve(count)
            .map_err(|_| FileError::ResourceLimit(path.into()))?;
        bytes.extend_from_slice(&chunk[..count]);
    }
    canceled(cancel)?;
    Ok(bytes)
}

pub fn read_text(path: &str, cancel: &AtomicBool) -> Result<TextFile, FileError> {
    let (mut file, stat) = regular_file(path, cancel)?;
    if stat.size > MAX_TEXT_BYTES as i64 {
        return Err(FileError::ResourceLimit(path.into()));
    }
    let mut bytes = Vec::new();
    let mut chunk = [0u8; CHUNK_BYTES];
    loop {
        canceled(cancel)?;
        let count = file
            .read(&mut chunk)
            .map_err(|error| win32_error(path, error))?;
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

struct Temporary {
    file: File,
    armed: bool,
}
impl Temporary {
    /// Marks the still-open temporary for deletion when its handle closes.
    fn cleanup(&mut self) -> io::Result<()> {
        if !self.armed {
            return Ok(());
        }
        let disposition = FILE_DISPOSITION_INFORMATION_EX {
            Flags: FILE_DISPOSITION_DELETE | FILE_DISPOSITION_POSIX_SEMANTICS,
        };
        // The handle is live, was opened with DELETE access, and the block is
        // exactly the fixed-size structure.
        set_information(
            self.file.as_raw_handle(),
            FileDispositionInformationEx,
            (&raw const disposition).cast(),
            std::mem::size_of::<FILE_DISPOSITION_INFORMATION_EX>(),
        )?;
        self.armed = false;
        Ok(())
    }
}
impl Drop for Temporary {
    fn drop(&mut self) {
        // Normal refusal explicitly reports cleanup errors. This fallback also
        // releases the name if a test callback unwinds before normal cleanup.
        let _ = self.cleanup();
    }
}

/// Atomically replaces one regular file through a same-directory private temp.
/// Existing file attributes (read-only excepted) are carried over; new files
/// are ordinary. Cancellation is checked before rename, which is the commit
/// point: once it succeeds the operation returns Written, even if cancellation
/// races afterward. The file is flushed before rename; the parent directory is
/// not, so this guarantees atomic replacement rather than power-loss
/// durability. Failed temporary cleanup is reported as Io and can leave the
/// temporary name behind. A blocked call keeps its worker reservation until it
/// returns.
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
    let (root, parts) = path_parts(path)?;
    if text.len() > MAX_TEXT_BYTES {
        return Err(FileError::ResourceLimit(path.into()));
    }
    let (name, parents) = parts
        .split_last()
        .ok_or_else(|| FileError::InvalidPath(path.into()))?;
    let parent = directory(&root, parents, path, cancel)?;
    let destination = name_units(name, path)?;
    let existing = match open_at(
        parent.as_raw_handle(),
        &destination,
        FILE_READ_ATTRIBUTES | SYNCHRONIZE,
        FILE_OPEN,
        0,
        0,
        path,
    ) {
        Ok(handle) => {
            let stat = handle_stat(&handle, path)?;
            if kind(stat.attributes) != Kind::File {
                return Err(FileError::InvalidPath(path.into()));
            }
            Some(stat.attributes)
        }
        Err(FileError::NotFound(_)) => None,
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
        let temporary = name_units(OsStr::new(&temporary), path)?;
        // Capture the code before formatting any diagnostic so only an
        // existing name is retried.
        match nt_open(
            parent.as_raw_handle(),
            &temporary,
            FILE_WRITE_DATA | FILE_WRITE_ATTRIBUTES | FILE_READ_ATTRIBUTES | DELETE | SYNCHRONIZE,
            FILE_CREATE,
            FILE_NON_DIRECTORY_FILE,
            FILE_ATTRIBUTE_NORMAL,
        ) {
            Ok(handle) => {
                created = Some(handle);
                break;
            }
            Err(error)
                if matches!(
                    error.raw_os_error().map(|code| code as u32),
                    Some(ERROR_ALREADY_EXISTS | ERROR_FILE_EXISTS)
                ) => {}
            Err(error) => return Err(win32_error(path, error)),
        }
    }
    let handle = created.ok_or_else(|| FileError::ResourceLimit(path.into()))?;
    let mut temporary = Temporary {
        file: File::from(handle),
        armed: true,
    };
    let result = (|| {
        for chunk in text.as_bytes().chunks(CHUNK_BYTES) {
            canceled(cancel)?;
            temporary
                .file
                .write_all(chunk)
                .map_err(|error| win32_error(path, error))?;
        }
        canceled(cancel)?;
        if let Some(attributes) = existing {
            let basic = FILE_BASIC_INFO {
                CreationTime: 0,
                LastAccessTime: 0,
                LastWriteTime: 0,
                ChangeTime: 0,
                FileAttributes: attributes
                    & !(FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY),
            };
            // SAFETY: the temporary is a live regular file owned by this request.
            if unsafe {
                SetFileInformationByHandle(
                    temporary.file.as_raw_handle(),
                    FileBasicInfo,
                    (&raw const basic).cast(),
                    std::mem::size_of::<FILE_BASIC_INFO>() as u32,
                )
            } == 0
            {
                return Err(win32_error(path, io::Error::last_os_error()));
            }
        }
        temporary
            .file
            .sync_all()
            .map_err(|error| win32_error(path, error))?;
        before_commit();
        canceled(cancel)?;
        rename_over(&temporary.file, parent.as_raw_handle(), &destination, path)?;
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

/// Recursively observes at most 10,000 entries and 64 directory levels.
/// Reparse points are reported without traversal; any invalid text, race, or
/// exceeded bound refuses the complete result. Returned paths are sorted for
/// stable display.
pub fn scan(root: &str, cancel: &AtomicBool) -> Result<Scan, FileError> {
    let (volume, parts) = path_parts(root)?;
    let directory = directory(&volume, &parts, root, cancel)?;
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

/// Reads a UTF-8 prefix of at most 64 KiB, reporting omitted bytes explicitly.
/// A code point cut by the prefix bound is excluded; invalid UTF-8 inside the
/// prefix or an incomplete terminal code point in a complete file is refused.
pub fn read_preview(path: &str, cancel: &AtomicBool) -> Result<Preview, FileError> {
    let (mut file, _) = regular_file(path, cancel)?;
    let mut bytes = read_chunk(&mut file, path, cancel, MAX_CHUNK_BYTES + 1, win32_error)?;
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

/// The opaque log cursor identity: the volume serial and the low 64 bits of
/// the 128-bit file identifier, which is the complete identifier on NTFS.
fn log_identity(stat: &Stat) -> (u64, u64) {
    let mut low = [0u8; 8];
    low.copy_from_slice(&stat.id.file[..8]);
    (stat.id.volume, u64::from_le_bytes(low))
}

/// Reads at most 64 KiB from a caller-owned cursor; the host retains no file or
/// cursor between requests. A changed volume/file identity restarts at zero as
/// Rotated; a shorter file restarts as Truncated. Same-identity truncate-and-
/// regrow between observations cannot be distinguished. Start reads history;
/// End seeds EOF after validating its terminal code point (not the skipped
/// history). An incomplete or invalid EOF code point refuses End with
/// InvalidUtf8. Only complete UTF-8 is consumed, so a partial terminal code
/// point is retried from the returned offset. Invalid bytes refuse the request.
/// Line assembly is the caller's bounded responsibility, and concurrent writes
/// are observations, not snapshots. Cancellation closes the request's
/// independently owned file.
pub fn read_log(
    path: &str,
    position: LogPosition,
    cancel: &AtomicBool,
) -> Result<LogChunk, FileError> {
    let (mut file, stat) = regular_file(path, cancel)?;
    let size = u64::try_from(stat.size).map_err(|_| FileError::InvalidPath(path.into()))?;
    let (device, inode) = log_identity(&stat);
    let mut cursor = LogCursor {
        device,
        inode,
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
            .map_err(|error| win32_error(path, error))?;
        let tail = read_chunk(&mut file, path, cancel, size.min(4) as usize, win32_error)?;
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
        .map_err(|error| win32_error(path, error))?;
    let mut bytes = read_chunk(&mut file, path, cancel, MAX_CHUNK_BYTES + 1, win32_error)?;
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

/// Requests the shell's associated application through the file protocol
/// handler that ships with Windows. Success means the shell accepted the
/// launch; it does not own the resulting application. Cancellation/deadline
/// kills and reaps the launcher but cannot undo a launch already handed off.
/// The path is validated through no-follow handles first; the external
/// application subsequently resolves that path and owns its own access policy.
/// Launcher stdout/stderr are never retained.
pub fn open_path(path: &str, cancel: &AtomicBool) -> Result<Opened, FileError> {
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
) -> Result<Opened, FileError> {
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
    use windows_sys::Win32::Foundation::ERROR_PRIVILEGE_NOT_HELD;

    struct Directory(std::path::PathBuf);
    impl Directory {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "signals-file-test-{}-{}",
                std::process::id(),
                TEMP_SERIAL.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&root).unwrap();
            // Strip the verbatim prefix canonicalize adds; apps pass drive paths.
            let canonical = root.canonicalize().unwrap();
            let text = canonical.to_str().unwrap();
            Self(text.strip_prefix(r"\\?\").unwrap_or(text).into())
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
    /// Symbolic links need a privilege or Developer Mode; junctions and a
    /// missing privilege both count as "skip", never as a pass.
    fn symlink_dir(target: &str, link: &str) -> bool {
        match std::os::windows::fs::symlink_dir(target, link) {
            Ok(()) => true,
            Err(error)
                if error.raw_os_error() == Some(ERROR_PRIVILEGE_NOT_HELD as i32)
                    || error.raw_os_error() == Some(ERROR_ACCESS_DENIED as i32) =>
            {
                eprintln!("skipping symlink assertions: {error}");
                false
            }
            Err(error) => panic!("{error}"),
        }
    }

    #[test]
    fn utf8_save_replaces_snapshot_atomically_and_preserves_attributes() {
        let dir = Directory::new();
        let path = dir.path("café.txt");
        let text = "First line\nSecond 🦀 café\n";
        let result = write_text(&path, text, &active(), 1).unwrap();
        assert_eq!(result.bytes, text.len() as u64);
        assert_eq!(read_text(&path, &active()).unwrap().text, text);
        write_text(&path, "", &active(), 2).unwrap();
        assert_eq!(read_text(&path, &active()).unwrap().text, "");
        assert_eq!(dir.names(), vec!["café.txt"]);
        // A forward-slash drive path is the same file.
        let slashed = path.replace('\\', "/");
        assert_eq!(read_text(&slashed, &active()).unwrap().text, "");
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
        // Replacing a directory entry with a file is refused at the commit point.
        let result = write_text_before_commit(&path, "next", &active(), 6, || {
            fs::remove_file(&path).unwrap();
            fs::create_dir(&path).unwrap();
        });
        assert!(
            matches!(
                result,
                Err(FileError::InvalidPath(_) | FileError::PermissionDenied(_) | FileError::Io(_))
            ),
            "{result:?}"
        );
        assert!(fs::metadata(&path).unwrap().is_dir());
        assert_eq!(dir.names(), vec!["draft.txt"]);
    }

    #[test]
    fn no_follow_handles_resist_parent_and_destination_link_replacement() {
        let dir = Directory::new();
        fs::create_dir(dir.path("real")).unwrap();
        fs::write(dir.path("real\\secret.txt"), "secret").unwrap();
        if !symlink_dir(&dir.path("real"), &dir.path("link")) {
            return;
        }
        assert!(matches!(
            read_text(&dir.path("link\\secret.txt"), &active()),
            Err(FileError::InvalidPath(_))
        ));
        assert!(matches!(
            write_text(&dir.path("link\\secret.txt"), "x", &active(), 7),
            Err(FileError::InvalidPath(_))
        ));
        assert_eq!(
            fs::read_to_string(dir.path("real\\secret.txt")).unwrap(),
            "secret"
        );
        let scanned = scan(dir.root(), &active()).unwrap();
        let link = scanned
            .entries
            .iter()
            .find(|entry| entry.path.ends_with("link"))
            .unwrap();
        assert_eq!(link.kind, Kind::SymbolicLink);
        assert!(
            !scanned
                .entries
                .iter()
                .any(|entry| entry.path.contains("link\\"))
        );
        // Windows refuses to rename a directory while a handle is open on it,
        // so a validated parent cannot be swapped for a link before commit; the
        // save lands in the directory that was opened.
        let path = dir.path("real\\draft.txt");
        write_text_before_commit(&path, "draft", &active(), 8, || {
            let error = fs::rename(dir.path("real"), dir.path("moved")).unwrap_err();
            assert_eq!(error.raw_os_error(), Some(ERROR_ACCESS_DENIED as i32));
        })
        .unwrap();
        assert_eq!(
            fs::read_to_string(dir.path("real\\draft.txt")).unwrap(),
            "draft"
        );
    }

    #[test]
    fn listing_reports_direct_children_only() {
        let dir = Directory::new();
        fs::create_dir_all(dir.path("b\\inner")).unwrap();
        fs::write(dir.path("b\\inner\\file.txt"), "12345").unwrap();
        fs::write(dir.path("a.txt"), "xy").unwrap();
        let listing = list_directory(dir.root(), &active()).unwrap();
        let listed: Vec<_> = listing
            .entries
            .iter()
            .map(|entry| {
                (
                    entry.path.strip_prefix(dir.root()).unwrap().to_string(),
                    entry.kind,
                    entry.bytes,
                )
            })
            .collect();
        assert_eq!(
            listed,
            vec![
                ("\\a.txt".to_string(), Kind::File, 2),
                ("\\b".to_string(), Kind::Directory, 0),
            ]
        );
        assert!(matches!(
            list_directory(&dir.path("a.txt"), &active()),
            Err(FileError::InvalidPath(_))
        ));
    }

    #[test]
    fn preview_bounds_text_and_excludes_a_cut_code_point() {
        let dir = Directory::new();
        let path = dir.path("preview.txt");
        fs::write(&path, format!("{}λtail", "x".repeat(MAX_CHUNK_BYTES - 1))).unwrap();
        let preview = read_preview(&path, &active()).unwrap();
        assert!(preview.truncated);
        assert_eq!(preview.text.len(), MAX_CHUNK_BYTES - 1);
        fs::write(&path, "short λ").unwrap();
        let preview = read_preview(&path, &active()).unwrap();
        assert!(!preview.truncated);
        assert_eq!(preview.text, "short λ");
        fs::write(&path, [b'a', 0xce]).unwrap();
        assert!(matches!(
            read_preview(&path, &active()),
            Err(FileError::InvalidUtf8(_))
        ));
    }

    #[test]
    fn log_cursor_continues_detects_rotation_and_truncation() {
        let dir = Directory::new();
        let path = dir.path("app.log");
        fs::write(&path, "one\n").unwrap();
        let first = read_log(&path, LogPosition::Start, &active()).unwrap();
        assert_eq!(
            (first.text.as_str(), first.change, first.state),
            ("one\n", LogChange::Initial, LogState::AtEnd)
        );
        fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap()
            .write_all("two\n".as_bytes())
            .unwrap();
        let second = read_log(&path, LogPosition::After(first.cursor), &active()).unwrap();
        assert_eq!(
            (second.text.as_str(), second.change),
            ("two\n", LogChange::Continued)
        );
        assert_eq!(second.cursor.offset, 8);
        fs::write(&path, "x").unwrap();
        let truncated = read_log(&path, LogPosition::After(second.cursor), &active()).unwrap();
        assert_eq!(
            (truncated.text.as_str(), truncated.change),
            ("x", LogChange::Truncated)
        );
        let rotated_cursor = LogCursor {
            inode: second.cursor.inode ^ 1,
            ..second.cursor
        };
        let rotated = read_log(&path, LogPosition::After(rotated_cursor), &active()).unwrap();
        assert_eq!(
            (rotated.text.as_str(), rotated.change),
            ("x", LogChange::Rotated)
        );
        fs::write(&path, "tail λ").unwrap();
        let end = read_log(&path, LogPosition::End, &active()).unwrap();
        assert_eq!(
            (end.text.as_str(), end.cursor.offset, end.state),
            ("", 7, LogState::AtEnd)
        );
        fs::write(&path, [b'a', 0xce]).unwrap();
        assert!(matches!(
            read_log(&path, LogPosition::End, &active()),
            Err(FileError::InvalidUtf8(_))
        ));
        let partial = read_log(&path, LogPosition::Start, &active()).unwrap();
        assert_eq!(
            (partial.text.as_str(), partial.cursor.offset, partial.state),
            ("a", 1, LogState::PartialUtf8)
        );
    }

    #[test]
    fn open_path_reports_launcher_outcomes() {
        let dir = Directory::new();
        let path = dir.path("open.txt");
        fs::write(&path, "x").unwrap();
        let system = std::env::var("SystemRoot").unwrap();
        let cmd = format!("{system}\\System32\\cmd.exe");
        open_path_with_launcher(
            &path,
            &active(),
            OsStr::new(&cmd),
            &[OsStr::new("/c"), OsStr::new("exit 0 &&")],
        )
        .unwrap();
        assert!(matches!(
            open_path_with_launcher(
                &path,
                &active(),
                OsStr::new(&cmd),
                &[OsStr::new("/c"), OsStr::new("exit 3 &&")]
            ),
            Err(FileError::Unavailable(_))
        ));
        assert!(matches!(
            open_path_with_launcher(&path, &active(), OsStr::new("missing-launcher.exe"), &[]),
            Err(FileError::Unavailable(_))
        ));
        let cancel = active();
        cancel.store(true, Ordering::Release);
        assert_eq!(open_path(&path, &cancel), Err(FileError::Canceled));
        assert!(matches!(
            open_path(&dir.path("missing.txt"), &active()),
            Err(FileError::NotFound(_))
        ));
    }

    #[test]
    fn scan_reports_nested_entries_sorted_with_sizes_and_kinds() {
        let dir = Directory::new();
        fs::create_dir_all(dir.path("b\\inner")).unwrap();
        fs::write(dir.path("b\\inner\\file.txt"), "12345").unwrap();
        fs::write(dir.path("a.txt"), "").unwrap();
        let scanned = scan(dir.root(), &active()).unwrap();
        let listed: Vec<_> = scanned
            .entries
            .iter()
            .map(|entry| {
                (
                    entry.path.strip_prefix(dir.root()).unwrap().to_string(),
                    entry.kind,
                    entry.bytes,
                )
            })
            .collect();
        assert_eq!(
            listed,
            vec![
                ("\\a.txt".to_string(), Kind::File, 0),
                ("\\b".to_string(), Kind::Directory, 0),
                ("\\b\\inner".to_string(), Kind::Directory, 0),
                ("\\b\\inner\\file.txt".to_string(), Kind::File, 5),
            ]
        );
        assert!(matches!(
            scan(&dir.path("a.txt"), &active()),
            Err(FileError::InvalidPath(_))
        ));
        assert!(matches!(
            scan(&dir.path("missing"), &active()),
            Err(FileError::NotFound(_))
        ));
    }

    #[test]
    fn text_limits_and_invalid_paths_refuse_without_partial_writes() {
        let dir = Directory::new();
        let path = dir.path("draft.txt");
        fs::write(&path, "kept").unwrap();
        let oversized = "x".repeat(MAX_TEXT_BYTES + 1);
        assert!(matches!(
            write_text(&path, &oversized, &active(), 9),
            Err(FileError::ResourceLimit(_))
        ));
        fs::write(dir.path("big.txt"), &oversized).unwrap();
        assert!(matches!(
            read_text(&dir.path("big.txt"), &active()),
            Err(FileError::ResourceLimit(_))
        ));
        fs::write(dir.path("latin1.txt"), [0xE9u8]).unwrap();
        assert!(matches!(
            read_text(&dir.path("latin1.txt"), &active()),
            Err(FileError::InvalidUtf8(_))
        ));
        for invalid in [
            "relative\\draft.txt".to_string(),
            dir.path("..\\draft.txt"),
            dir.path("nul\0name"),
            format!("\\\\server\\share\\{}", "draft.txt"),
            format!("{}\\{}", dir.root(), "x".repeat(MAX_PATH_BYTES)),
        ] {
            let Err(FileError::InvalidPath(message)) = write_text(&invalid, "x", &active(), 10)
            else {
                panic!("invalid path accepted: {invalid:?}")
            };
            assert!(message.len() <= super::super::MAX_ERROR_DETAIL_BYTES);
        }
        assert_eq!(fs::read_to_string(&path).unwrap(), "kept");
        assert!(matches!(
            read_text(&dir.path("missing.txt"), &active()),
            Err(FileError::NotFound(_))
        ));
        let directory_read = read_text(dir.root(), &active());
        assert!(
            matches!(directory_read, Err(FileError::InvalidPath(_))),
            "{directory_read:?}"
        );
    }
}
