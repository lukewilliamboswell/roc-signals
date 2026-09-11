//! Native filesystem services for the hosted `Files` functions. Each request
//! arrives from an effect worker with its arguments as plain buffers, runs to
//! completion there, and hands its result back as C structs the Zig host
//! copies into Roc values. Choosers are the one kind that waits for the UI
//! thread to show a dialog.
use crate::{
    Runtime,
    assets::{self, AssetStatus},
    file_io::{self, FileError, Kind, LogChange, LogCursor, LogPosition, LogState},
    workers,
};
use gpui::{Context, PathPromptOptions};
use std::{
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
};

/// An owned byte buffer handed to the Zig host. The host copies it into a Roc
/// value and returns it through `signals_bytes_release`.
#[repr(C)]
pub(crate) struct Bytes {
    ptr: *mut u8,
    len: usize,
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

#[repr(C)]
pub(crate) struct AssetEntryIn {
    name_ptr: *const u8,
    name_len: usize,
    sha_ptr: *const u8,
    sha_len: usize,
}

#[repr(C)]
pub(crate) struct AssetResultOut {
    name: Bytes,
    status: u32,
}

#[repr(C)]
pub(crate) struct AssetResultsOut {
    ptr: *mut AssetResultOut,
    len: usize,
    cap: usize,
}

#[repr(C)]
pub(crate) struct LogCursorOut {
    device: u64,
    inode: u64,
    offset: u64,
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

/// Identities for write requests, which name their temporary files.
fn next_request_id() -> u64 {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1 << 62);
    NEXT.fetch_add(1, Ordering::Relaxed)
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

#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_files_read_text(
    path: *const u8,
    path_len: usize,
    out_path: *mut Bytes,
    out_text: *mut Bytes,
    err: *mut FilesErrorOut,
) -> u32 {
    let result = unsafe { text(path, path_len, "path") }
        .and_then(|path| file_io::read_text(path, &AtomicBool::new(false)));
    deliver(result, err, |file| unsafe {
        out_path.write(Bytes::from_string(file.path));
        out_text.write(Bytes::from_string(file.text));
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_files_write_text(
    path: *const u8,
    path_len: usize,
    text_ptr: *const u8,
    text_len: usize,
    out_path: *mut Bytes,
    out_bytes: *mut u64,
    err: *mut FilesErrorOut,
) -> u32 {
    let result = unsafe { text(path, path_len, "path") }.and_then(|path| {
        let body = unsafe { text(text_ptr, text_len, "text") }?;
        file_io::write_text(path, body, &AtomicBool::new(false), next_request_id())
    });
    deliver(result, err, |written| unsafe {
        out_path.write(Bytes::from_string(written.path));
        out_bytes.write(written.bytes);
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_files_scan(
    root: *const u8,
    root_len: usize,
    out_root: *mut Bytes,
    out_entries: *mut FileEntriesOut,
    err: *mut FilesErrorOut,
) -> u32 {
    let result = unsafe { text(root, root_len, "root") }
        .and_then(|root| file_io::scan(root, &AtomicBool::new(false)));
    deliver(result, err, |scan| unsafe {
        out_root.write(Bytes::from_string(scan.root));
        out_entries.write(entries_out(scan.entries));
    })
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
    out_path: *mut Bytes,
    err: *mut FilesErrorOut,
) -> u32 {
    let result = unsafe { text(path, path_len, "path") }
        .and_then(|path| file_io::open_path(path, &AtomicBool::new(false)));
    deliver(result, err, |opened| unsafe {
        out_path.write(Bytes::from_string(opened.path));
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_files_read_preview(
    path: *const u8,
    path_len: usize,
    out_path: *mut Bytes,
    out_text: *mut Bytes,
    out_truncated: *mut u32,
    err: *mut FilesErrorOut,
) -> u32 {
    let result = unsafe { text(path, path_len, "path") }
        .and_then(|path| file_io::read_preview(path, &AtomicBool::new(false)));
    deliver(result, err, |preview| unsafe {
        out_path.write(Bytes::from_string(preview.path));
        out_text.write(Bytes::from_string(preview.text));
        out_truncated.write(u32::from(preview.truncated));
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_files_read_log(
    path: *const u8,
    path_len: usize,
    position: u32,
    device: u64,
    inode: u64,
    offset: u64,
    out_path: *mut Bytes,
    out_text: *mut Bytes,
    out_cursor: *mut LogCursorOut,
    out_change: *mut u32,
    out_state: *mut u32,
    err: *mut FilesErrorOut,
) -> u32 {
    let position = match position {
        0 => LogPosition::Start,
        1 => LogPosition::End,
        _ => LogPosition::After(LogCursor {
            device,
            inode,
            offset,
        }),
    };
    let result = unsafe { text(path, path_len, "path") }
        .and_then(|path| file_io::read_log(path, position, &AtomicBool::new(false)));
    deliver(result, err, |chunk| unsafe {
        out_path.write(Bytes::from_string(chunk.path));
        out_text.write(Bytes::from_string(chunk.text));
        out_cursor.write(LogCursorOut {
            device: chunk.cursor.device,
            inode: chunk.cursor.inode,
            offset: chunk.cursor.offset,
        });
        out_change.write(match chunk.change {
            LogChange::Initial => 0,
            LogChange::Continued => 1,
            LogChange::Rotated => 2,
            LogChange::Truncated => 3,
        });
        out_state.write(match chunk.state {
            LogState::More => 0,
            LogState::AtEnd => 1,
            LogState::PartialUtf8 => 2,
        });
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_files_verify_assets(
    entries: *const AssetEntryIn,
    count: usize,
    out: *mut AssetResultsOut,
    err: *mut FilesErrorOut,
) -> u32 {
    let decoded = (|| {
        if count == 0 || count > assets::MAX_MANIFEST_ASSETS {
            return Err(FileError::InvalidPath(
                "asset manifests contain 1 to 256 entries".into(),
            ));
        }
        let inputs = unsafe { std::slice::from_raw_parts(entries, count) };
        let mut manifest = Vec::with_capacity(count);
        for input in inputs {
            let name = unsafe { text(input.name_ptr, input.name_len, "asset name") }?;
            if name.is_empty() || name.len() > assets::MAX_SOURCE_BYTES {
                return Err(FileError::InvalidPath(
                    "asset names contain 1 to 1024 UTF-8 bytes".into(),
                ));
            }
            let digest = unsafe { text(input.sha_ptr, input.sha_len, "asset digest") }?;
            let hex = digest.len() == 64
                && digest
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte));
            if !hex {
                return Err(FileError::InvalidPath(
                    "asset digests are 64 lowercase hex characters".into(),
                ));
            }
            manifest.push((name.to_owned(), digest.to_owned()));
        }
        assets::verify(&manifest, &AtomicBool::new(false))
    })();
    deliver(decoded, err, |report| {
        let mut results: Vec<AssetResultOut> = report
            .into_iter()
            .map(|(name, status)| AssetResultOut {
                name: Bytes::from_string(name),
                status: match status {
                    AssetStatus::Ok => 0,
                    AssetStatus::Missing => 1,
                    AssetStatus::Mismatch => 2,
                },
            })
            .collect();
        let value = AssetResultsOut {
            ptr: results.as_mut_ptr(),
            len: results.len(),
            cap: results.capacity(),
        };
        std::mem::forget(results);
        unsafe { out.write(value) };
    })
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

#[unsafe(no_mangle)]
pub unsafe extern "C" fn signals_asset_results_release(results: AssetResultsOut) {
    if results.ptr.is_null() {
        return;
    }
    for result in unsafe { Vec::from_raw_parts(results.ptr, results.len, results.cap) } {
        unsafe { result.name.release() };
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
    }
}
