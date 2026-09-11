//! Native filesystem services for the hosted `Files` functions. Each request
//! arrives from an effect worker with its arguments as plain buffers, runs to
//! completion there, and hands its result back as C structs the Zig host
//! copies into Roc values. Choosers are the one kind that waits for the UI
//! thread to show a dialog.
use crate::{
    Runtime, assets,
    file_io::{self, FileError, Kind},
    workers,
};
use gpui::{Context, PathPromptOptions};
use std::{
    path::{Path, PathBuf},
    sync::{
        atomic::AtomicBool,
        mpsc,
    },
};

/// An owned byte buffer handed to the Zig host. The host copies it into a Roc
/// value and returns it through `signals_bytes_release`.
#[repr(C)]
pub(crate) struct Bytes {
    ptr: *mut u8,
    pub(crate) len: usize,
    cap: usize,
}

impl Bytes {
    pub(crate) fn from_vec(vec: Vec<u8>) -> Self {
        let mut vec = vec;
        let bytes = Self {
            ptr: vec.as_mut_ptr(),
            len: vec.len(),
            cap: vec.capacity(),
        };
        std::mem::forget(vec);
        bytes
    }
    pub(crate) fn from_string(text: String) -> Self {
        Self::from_vec(text.into_bytes())
    }
    /// Reclaims the buffer; a buffer the host never filled is a valid empty vector.
    unsafe fn release(self) {
        if self.ptr.is_null() {
            return;
        }
        drop(unsafe { Vec::from_raw_parts(self.ptr, self.len, self.cap) });
    }
}

#[repr(C)]
pub(crate) struct FilesErrorOut {
    kind: u32,
    detail: Bytes,
}

#[repr(C)]
pub(crate) struct FileEntryOut {
    path: Bytes,
    bytes: u64,
    kind: u32,
}

#[repr(C)]
pub(crate) struct FileEntriesOut {
    ptr: *mut FileEntryOut,
    len: usize,
    cap: usize,
}


/// Every operation reports failure through the same struct; the kind numbers
/// are the ones `native_services.zig` maps onto the Roc `Files.Error` tags.
pub(crate) fn error_out(error: FileError) -> FilesErrorOut {
    let (kind, detail) = match error {
        FileError::Canceled => (0, String::new()),
        FileError::NotFound(detail) => (1, detail),
        FileError::PermissionDenied(detail) => (2, detail),
        FileError::InvalidUtf8(detail) => (3, detail),
        FileError::InvalidPath(detail) => (4, detail),
        FileError::ResourceLimit(detail) => (5, detail),
        FileError::Io(detail) => (6, detail),
        FileError::Unavailable(detail) => (7, detail),
    };
    FilesErrorOut {
        kind,
        detail: Bytes::from_string(file_io::bounded_detail(detail)),
    }
}

/// Views a Roc string argument; Roc strings are UTF-8 by construction.
unsafe fn text<'a>(ptr: *const u8, len: usize, what: &str) -> Result<&'a str, FileError> {
    if len == 0 {
        return Ok("");
    }
    std::str::from_utf8(unsafe { std::slice::from_raw_parts(ptr, len) })
        .map_err(|_| FileError::InvalidUtf8(what.into()))
}

fn entries_out(entries: Vec<file_io::Entry>) -> FileEntriesOut {
    let mut out: Vec<FileEntryOut> = entries
        .into_iter()
        .map(|entry| FileEntryOut {
            path: Bytes::from_string(entry.path),
            bytes: entry.bytes,
            kind: match entry.kind {
                Kind::File => 0,
                Kind::Directory => 1,
                Kind::SymbolicLink => 2,
                Kind::Other => 3,
            },
        })
        .collect();
    let result = FileEntriesOut {
        ptr: out.as_mut_ptr(),
        len: out.len(),
        cap: out.capacity(),
    };
    std::mem::forget(out);
    result
}


fn deliver<T>(result: Result<T, FileError>, err: *mut FilesErrorOut, on_ok: impl FnOnce(T)) -> u32 {
    match result {
        Ok(value) => {
            on_ok(value);
            0
        }
        Err(error) => {
            unsafe { err.write(error_out(error)) };
            1
        }
    }
}

#[repr(C)]
pub(crate) struct StatOut {
    kind: u32,
    size: u64,
    device: u64,
    inode: u64,
}

fn kind_out(kind: Kind) -> u32 {
    match kind {
        Kind::File => 0,
        Kind::Directory => 1,
        Kind::SymbolicLink => 2,
        Kind::Other => 3,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_files_stat(
    path: *const u8,
    path_len: usize,
    out: *mut StatOut,
    err: *mut FilesErrorOut,
) -> u32 {
    let result = unsafe { text(path, path_len, "path") }
        .and_then(|path| file_io::stat(path, &AtomicBool::new(false)));
    deliver(result, err, |meta| unsafe {
        out.write(StatOut {
            kind: kind_out(meta.kind),
            size: meta.size,
            device: meta.device,
            inode: meta.inode,
        });
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_files_read_bytes(
    path: *const u8,
    path_len: usize,
    offset: u64,
    max_bytes: u64,
    out_bytes: *mut Bytes,
    out_size: *mut u64,
    err: *mut FilesErrorOut,
) -> u32 {
    let max = max_bytes.min(usize::MAX as u64) as usize;
    let result = unsafe { text(path, path_len, "path") }
        .and_then(|path| file_io::read_at(path, offset, max, &AtomicBool::new(false)));
    deliver(result, err, |(bytes, size)| unsafe {
        out_bytes.write(Bytes::from_vec(bytes));
        out_size.write(size);
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_files_write_bytes(
    path: *const u8,
    path_len: usize,
    bytes: *const u8,
    bytes_len: usize,
    err: *mut FilesErrorOut,
) -> u32 {
    let content: &[u8] = if bytes_len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(bytes, bytes_len) }
    };
    let result = unsafe { text(path, path_len, "path") }
        .and_then(|path| file_io::write_bytes(path, content, &AtomicBool::new(false)));
    deliver(result, err, |()| {})
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_files_rename(
    from: *const u8,
    from_len: usize,
    to: *const u8,
    to_len: usize,
    err: *mut FilesErrorOut,
) -> u32 {
    let result = unsafe { text(from, from_len, "from") }.and_then(|from| {
        let to = unsafe { text(to, to_len, "to") }?;
        file_io::rename(from, to, &AtomicBool::new(false))
    });
    deliver(result, err, |()| {})
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_files_remove(
    path: *const u8,
    path_len: usize,
    err: *mut FilesErrorOut,
) -> u32 {
    let result = unsafe { text(path, path_len, "path") }
        .and_then(|path| file_io::remove(path, &AtomicBool::new(false)));
    deliver(result, err, |()| {})
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_files_sync(
    path: *const u8,
    path_len: usize,
    err: *mut FilesErrorOut,
) -> u32 {
    let result = unsafe { text(path, path_len, "path") }
        .and_then(|path| file_io::sync(path, &AtomicBool::new(false)));
    deliver(result, err, |()| {})
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_files_list_directory(
    path: *const u8,
    path_len: usize,
    out_path: *mut Bytes,
    out_entries: *mut FileEntriesOut,
    err: *mut FilesErrorOut,
) -> u32 {
    let result = unsafe { text(path, path_len, "path") }
        .and_then(|path| file_io::list_directory(path, &AtomicBool::new(false)));
    deliver(result, err, |listing| unsafe {
        out_path.write(Bytes::from_string(listing.path));
        out_entries.write(entries_out(listing.entries));
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_files_open_path(
    path: *const u8,
    path_len: usize,
    err: *mut FilesErrorOut,
) -> u32 {
    let result = unsafe { text(path, path_len, "path") }
        .and_then(|path| file_io::open_path(path, &AtomicBool::new(false)));
    deliver(result, err, |_| {})
}

/// The folder relative asset sources resolve against, as the host was launched.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_files_assets_root(out: *mut Bytes) {
    let root = assets::root().to_string_lossy().into_owned();
    unsafe { out.write(Bytes::from_string(root)) };
}

/// Shows a chooser for a waiting worker and answers it with the chosen path,
/// `None` when the user dismissed the dialog.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_files_choose(
    kind: u32,
    directory: *const u8,
    directory_len: usize,
    home: u32,
    name: *const u8,
    name_len: usize,
    out_path: *mut Bytes,
    out_canceled: *mut u32,
    err: *mut FilesErrorOut,
) -> u32 {
    let request = (|| {
        Ok(match kind {
            0 => Chooser::File,
            1 => Chooser::Directory,
            _ => Chooser::SavePath {
                directory: if home != 0 {
                    Directory::Home
                } else {
                    Directory::At(unsafe { text(directory, directory_len, "directory") }?.to_owned())
                },
                suggested_name: unsafe { text(name, name_len, "suggested name") }?.to_owned(),
            },
        })
    })();
    let result = request.and_then(wait_for_chooser).and_then(|choice| match choice {
        None => Ok(None),
        Some(path) => {
            let path = path
                .to_str()
                .ok_or_else(|| FileError::InvalidUtf8("selected path".into()))?;
            validate_path(path)?;
            Ok(Some(path.to_owned()))
        }
    });
    deliver(result, err, |choice| unsafe {
        match choice {
            None => {
                out_canceled.write(1);
                out_path.write(Bytes::from_vec(Vec::new()));
            }
            Some(path) => {
                out_canceled.write(0);
                out_path.write(Bytes::from_string(path));
            }
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_bytes_release(bytes: Bytes) {
    unsafe { bytes.release() }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_file_entries_release(entries: FileEntriesOut) {
    if entries.ptr.is_null() {
        return;
    }
    for entry in unsafe { Vec::from_raw_parts(entries.ptr, entries.len, entries.cap) } {
        unsafe { entry.path.release() };
    }
}


enum Chooser {
    File,
    Directory,
    SavePath {
        directory: Directory,
        suggested_name: String,
    },
}

enum Directory {
    Home,
    At(String),
}

impl Directory {
    fn resolve(self) -> Result<String, FileError> {
        match self {
            Self::Home => std::env::var("HOME")
                .map_err(|_| FileError::Unavailable("HOME is missing or is not UTF-8".into())),
            Self::At(path) => Ok(path),
        }
    }
}

/// A chooser a worker effect is waiting on. The worker blocks on the other
/// end of `reply` until the dialog closes.
pub(crate) struct ChooserRequest {
    request: Chooser,
    reply: mpsc::Sender<Result<Option<PathBuf>, FileError>>,
}

/// Asks the UI thread to show a chooser and blocks the calling worker until
/// the user answers. Without a listening window there is nobody to show it.
fn wait_for_chooser(request: Chooser) -> Result<Option<PathBuf>, FileError> {
    let (reply, receiver) = mpsc::channel();
    if !workers::post(workers::Message::Chooser(ChooserRequest { request, reply })) {
        return Err(FileError::Unavailable(
            "no window is open to show a file chooser".into(),
        ));
    }
    receiver.recv().map_err(|_| {
        FileError::Unavailable("the window closed before the file chooser answered".into())
    })?
}

/// Shows the dialog a worker asked for and answers it when the dialog closes.
/// The worker is blocked on `reply` in `signals_files_choose`.
pub(crate) fn prompt(waiting: ChooserRequest, cx: &mut Context<Runtime>) {
    let ChooserRequest { request, reply } = waiting;
    match request {
        Chooser::File | Chooser::Directory => {
            let directories = matches!(request, Chooser::Directory);
            let receiver = cx.prompt_for_paths(PathPromptOptions {
                files: !directories,
                directories,
                multiple: false,
                prompt: None,
            });
            cx.spawn(async move |_, _| {
                let result = match receiver.await {
                    Ok(Ok(Some(mut paths))) if paths.len() == 1 => Ok(Some(paths.remove(0))),
                    Ok(Ok(None)) => Ok(None),
                    Ok(Ok(Some(_))) => Err(FileError::Unavailable(
                        "single-path chooser returned an invalid selection count".into(),
                    )),
                    Ok(Err(error)) => Err(FileError::Unavailable(error.to_string())),
                    Err(error) => Err(FileError::Unavailable(error.to_string())),
                };
                let _ = reply.send(result);
            })
            .detach();
        }
        Chooser::SavePath {
            directory,
            suggested_name,
        } => {
            let directory = match directory.resolve().and_then(|directory| {
                validate_save_options(&directory, &suggested_name).map(|_| directory)
            }) {
                Ok(directory) => directory,
                Err(error) => {
                    let _ = reply.send(Err(error));
                    return;
                }
            };
            let receiver = cx.prompt_for_new_path(Path::new(&directory), Some(&suggested_name));
            cx.spawn(async move |_, _| {
                let result = match receiver.await {
                    Ok(Ok(path)) => Ok(path),
                    Ok(Err(error)) => Err(FileError::Unavailable(error.to_string())),
                    Err(error) => Err(FileError::Unavailable(error.to_string())),
                };
                let _ = reply.send(result);
            })
            .detach();
        }
    }
}

fn validate_path(path: &str) -> Result<(), FileError> {
    if path.len() > 4096 {
        return Err(FileError::InvalidPath("path exceeds 4096 bytes".into()));
    }
    if !Path::new(path).is_absolute() || path.contains('\0') {
        return Err(FileError::InvalidPath(path.into()));
    }
    Ok(())
}

fn validate_save_options(directory: &str, name: &str) -> Result<(), FileError> {
    validate_path(directory)?;
    if name.len() > 255 {
        return Err(FileError::InvalidPath(
            "suggested file name exceeds 255 UTF-8 bytes".into(),
        ));
    }
    let separator = name.contains('/') || (cfg!(windows) && name.contains('\\'));
    if name.is_empty() || separator || name.contains('\0') || name == "." || name == ".." {
        return Err(FileError::InvalidPath(name.into()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn save_options_and_paths_are_validated() {
        assert!(validate_save_options("/tmp", "../escape").is_err());
        assert!(validate_save_options("relative", "note.txt").is_err());
        assert!(validate_save_options("/tmp", "note.txt").is_ok());
        assert!(validate_path("/tmp/a\0b").is_err());
    }

    #[test]
    fn error_details_are_bounded_and_kinds_are_stable() {
        let out = error_out(FileError::NotFound("x".repeat(5000)));
        assert_eq!(out.kind, 1);
        assert!(out.detail.len <= 4096);
        unsafe { out.detail.release() };
        let out = error_out(FileError::Canceled);
        assert_eq!((out.kind, out.detail.len), (0, 0));
        unsafe { out.detail.release() };
    }

    #[test]
    fn entries_round_trip_through_the_out_struct() {
        let entries = entries_out(vec![file_io::Entry {
            path: "/tmp/a".into(),
            kind: Kind::SymbolicLink,
            bytes: 7,
        }]);
        assert_eq!(entries.len, 1);
        let first = unsafe { &*entries.ptr };
        assert_eq!((first.kind, first.bytes), (2, 7));
        unsafe { signals_file_entries_release(entries) };
        assert_eq!(kind_out(Kind::Other), 3);
    }
}
