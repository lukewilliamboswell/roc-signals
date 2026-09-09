//! Native service adapter. Only owned primitive requests leave the UI thread;
//! all task identity, cancellation state, and result propagation belong to Zig.
use crate::{
    Runtime,
    bridge::Effect,
    file_io::{self, FileError, Kind, LogChange, LogCursor, LogPosition, LogState},
};
use gpui::{Context, PathPromptOptions};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};

const MAX_REQUESTS: usize = 16;
const MAX_PACKET: usize = 8 * 1024 * 1024;

#[derive(Default)]
pub(crate) struct Manager {
    jobs: HashMap<u64, Arc<AtomicBool>>,
}

impl Manager {
    pub(crate) fn accept(&mut self, message: Effect, cx: &mut Context<Runtime>) {
        match message {
            Effect::Cancel(id) => self
                .jobs
                .get(&id)
                .expect("cancel for unknown native worker")
                .store(true, Ordering::Release),
            Effect::Start { id, kind, request } => {
                assert!(
                    self.jobs.len() < MAX_REQUESTS,
                    "engine exceeded native task capacity"
                );
                let request =
                    Request::decode(kind, &request).expect("malformed native Files request");
                let cancel = Arc::new(AtomicBool::new(false));
                assert!(
                    self.jobs.insert(id, cancel.clone()).is_none(),
                    "duplicate native task identity"
                );
                match request {
                    Request::ChooseFile | Request::ChooseDirectory => {
                        let directories = matches!(request, Request::ChooseDirectory);
                        let receiver = cx.prompt_for_paths(PathPromptOptions {
                            files: !directories,
                            directories,
                            multiple: false,
                            prompt: None,
                        });
                        cx.spawn(async move |runtime, cx| {
                            let result = match receiver.await {
                                Ok(Ok(Some(mut paths))) if paths.len() == 1 => {
                                    choice(Some(paths.remove(0)))
                                }
                                Ok(Ok(None)) => choice(None),
                                Ok(Ok(Some(_))) => Err(FileError::Unavailable(
                                    "single-path chooser returned an invalid selection count"
                                        .into(),
                                )),
                                Ok(Err(error)) => Err(FileError::Unavailable(error.to_string())),
                                Err(error) => Err(FileError::Unavailable(error.to_string())),
                            };
                            let (failed, payload) = settle(result, &cancel);
                            let _ = runtime.update(cx, |runtime, cx| {
                                runtime.complete_task(id, failed, &payload, cx)
                            });
                        })
                        .detach();
                    }
                    Request::ChooseSavePath {
                        directory,
                        suggested_name,
                    } => {
                        let directory = match directory.resolve() {
                            Ok(directory) => directory,
                            Err(error) => {
                                self.deliver(id, Err(error), cancel, cx);
                                return;
                            }
                        };
                        if let Err(error) = validate_save_options(&directory, &suggested_name) {
                            self.deliver(id, Err(error), cancel, cx);
                            return;
                        }
                        let receiver =
                            cx.prompt_for_new_path(Path::new(&directory), Some(&suggested_name));
                        cx.spawn(async move |runtime, cx| {
                            let result = match receiver.await {
                                Ok(Ok(path)) => choice(path),
                                Ok(Err(error)) => Err(FileError::Unavailable(error.to_string())),
                                Err(error) => Err(FileError::Unavailable(error.to_string())),
                            };
                            let (failed, payload) = settle(result, &cancel);
                            let _ = runtime.update(cx, |runtime, cx| {
                                runtime.complete_task(id, failed, &payload, cx)
                            });
                        })
                        .detach();
                    }
                    request => {
                        let worker_cancel = cancel.clone();
                        let worker = cx.background_executor().spawn(async move {
                            match request {
                                Request::ReadText(path) => {
                                    file_io::read_text(&path, &worker_cancel)
                                        .map(|file| packet(&[&file.path, &file.text]))
                                }
                                Request::WriteText { path, text } => {
                                    file_io::write_text(&path, &text, &worker_cancel, id)
                                        .map(|file| packet(&[&file.path, &file.bytes.to_string()]))
                                }
                                Request::Scan(path) => {
                                    file_io::scan(&path, &worker_cancel).map(scan_packet)
                                }
                                Request::ListDirectory(path) => {
                                    file_io::list_directory(&path, &worker_cancel).map(|listing| {
                                        entries_packet(&listing.path, listing.entries)
                                    })
                                }
                                Request::OpenPath(path) => {
                                    file_io::open_path(&path, &worker_cancel)
                                        .map(|opened| packet(&[&opened.path]))
                                }
                                Request::ReadPreview(path) => {
                                    file_io::read_preview(&path, &worker_cancel).map(|preview| {
                                        packet(&[
                                            &preview.path,
                                            &preview.text,
                                            if preview.truncated { "true" } else { "false" },
                                        ])
                                    })
                                }
                                Request::ReadLog { path, position } => {
                                    file_io::read_log(&path, position, &worker_cancel)
                                        .map(log_packet)
                                }
                                _ => unreachable!(),
                            }
                        });
                        cx.spawn(async move |runtime, cx| {
                            // A successful save may already have committed its rename.
                            // The engine still rejects canceled delivery by request ID.
                            let result = worker.await;
                            let (failed, payload) = encode_result(result);
                            let _ = runtime.update(cx, |runtime, cx| {
                                runtime.complete_task(id, failed, &payload, cx)
                            });
                        })
                        .detach();
                    }
                }
            }
        }
    }

    fn deliver(
        &self,
        id: u64,
        result: Result<String, FileError>,
        cancel: Arc<AtomicBool>,
        cx: &mut Context<Runtime>,
    ) {
        cx.spawn(async move |runtime, cx| {
            let (failed, payload) = settle(result, &cancel);
            let _ = runtime.update(cx, |runtime, cx| {
                runtime.complete_task(id, failed, &payload, cx)
            });
        })
        .detach();
    }

    pub(crate) fn complete(&mut self, id: u64) {
        assert!(
            self.jobs.remove(&id).is_some(),
            "completion for unknown native worker"
        );
    }

    pub(crate) fn shutdown(&mut self) {
        for cancel in self.jobs.values() {
            cancel.store(true, Ordering::Release);
        }
        self.jobs.clear();
    }
}

impl Drop for Manager {
    fn drop(&mut self) {
        self.shutdown();
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Request {
    ChooseFile,
    ChooseDirectory,
    ChooseSavePath {
        directory: Directory,
        suggested_name: String,
    },
    ReadText(String),
    WriteText {
        path: String,
        text: String,
    },
    Scan(String),
    ListDirectory(String),
    OpenPath(String),
    ReadPreview(String),
    ReadLog {
        path: String,
        position: LogPosition,
    },
}

#[derive(Debug, PartialEq, Eq)]
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

impl Request {
    fn decode(kind: u32, payload: &str) -> Result<Self, &'static str> {
        if payload.len() > MAX_PACKET {
            return Err("packet limit");
        }
        let mut reader = Reader(payload);
        if reader.frame()? != "files1" {
            return Err("unsupported codec");
        }
        let request = match kind {
            1 => Self::ChooseFile,
            2 => Self::ChooseDirectory,
            3 => {
                let kind = reader.frame()?;
                let path = reader.frame()?;
                let directory = match (kind, path) {
                    ("home", "") => Directory::Home,
                    ("at", path) => Directory::At(path.into()),
                    _ => return Err("invalid save directory"),
                };
                Self::ChooseSavePath {
                    directory,
                    suggested_name: reader.frame()?.into(),
                }
            }
            4 => Self::ReadText(reader.frame()?.into()),
            5 => Self::WriteText {
                path: reader.frame()?.into(),
                text: reader.frame()?.into(),
            },
            6 => Self::Scan(reader.frame()?.into()),
            7 => Self::ListDirectory(reader.frame()?.into()),
            8 => Self::OpenPath(reader.frame()?.into()),
            9 => Self::ReadPreview(reader.frame()?.into()),
            10 => {
                let path = reader.frame()?.into();
                let position = reader.frame()?;
                let device = reader.number()?;
                let inode = reader.number()?;
                let offset = reader.number()?;
                let position = match (position, device, inode, offset) {
                    ("start", 0, 0, 0) => LogPosition::Start,
                    ("end", 0, 0, 0) => LogPosition::End,
                    ("after", device, inode, offset) => LogPosition::After(LogCursor {
                        device,
                        inode,
                        offset,
                    }),
                    _ => return Err("invalid log cursor"),
                };
                Self::ReadLog { path, position }
            }
            _ => return Err("unknown task kind"),
        };
        if !reader.0.is_empty() {
            return Err("trailing fields");
        }
        Ok(request)
    }
}

struct Reader<'a>(&'a str);
impl<'a> Reader<'a> {
    fn number(&mut self) -> Result<u64, &'static str> {
        let frame = self.frame()?;
        let value = frame
            .parse::<u64>()
            .map_err(|_| "invalid unsigned number")?;
        if value.to_string() != frame {
            return Err("noncanonical unsigned number");
        }
        Ok(value)
    }
    fn frame(&mut self) -> Result<&'a str, &'static str> {
        let (length, rest) = self.0.split_once(':').ok_or("missing length")?;
        let length_value = length.parse::<usize>().map_err(|_| "invalid length")?;
        if length_value.to_string() != length {
            return Err("noncanonical length");
        }
        let value = rest
            .get(..length_value)
            .ok_or("truncated frame or split UTF-8")?;
        self.0 = &rest[length_value..];
        Ok(value)
    }
}

fn append_frame(output: &mut String, value: &str) {
    use std::fmt::Write;
    write!(output, "{}:", value.len()).unwrap();
    output.push_str(value);
    assert!(
        output.len() <= MAX_PACKET,
        "native Files result exceeded packet bound"
    );
}

fn packet(fields: &[&str]) -> String {
    let mut output = String::new();
    append_frame(&mut output, "files1");
    for field in fields {
        append_frame(&mut output, field);
    }
    output
}

fn scan_packet(scan: file_io::Scan) -> String {
    entries_packet(&scan.root, scan.entries)
}

fn entries_packet(path: &str, entries: Vec<file_io::Entry>) -> String {
    let mut output = packet(&[path, &entries.len().to_string()]);
    for entry in entries {
        append_frame(&mut output, &entry.path);
        append_frame(
            &mut output,
            match entry.kind {
                Kind::File => "file",
                Kind::Directory => "directory",
                Kind::SymbolicLink => "symbolic-link",
                Kind::Other => "other",
            },
        );
        append_frame(&mut output, &entry.bytes.to_string());
    }
    output
}

fn log_packet(chunk: file_io::LogChunk) -> String {
    packet(&[
        &chunk.path,
        &chunk.text,
        &chunk.cursor.device.to_string(),
        &chunk.cursor.inode.to_string(),
        &chunk.cursor.offset.to_string(),
        match chunk.change {
            LogChange::Initial => "initial",
            LogChange::Continued => "continued",
            LogChange::Rotated => "rotated",
            LogChange::Truncated => "truncated",
        },
        match chunk.state {
            LogState::More => "more",
            LogState::AtEnd => "at-end",
            LogState::PartialUtf8 => "partial-utf8",
        },
    ])
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

fn choice(path: Option<PathBuf>) -> Result<String, FileError> {
    match path {
        None => Ok(packet(&["canceled"])),
        Some(path) => {
            let path = path
                .to_str()
                .ok_or_else(|| FileError::InvalidUtf8("selected path".into()))?;
            validate_path(path)?;
            Ok(packet(&["chosen", path]))
        }
    }
}

fn settle(result: Result<String, FileError>, cancel: &AtomicBool) -> (bool, String) {
    encode_result(if cancel.load(Ordering::Acquire) {
        Err(FileError::Canceled)
    } else {
        result
    })
}

fn encode_result(result: Result<String, FileError>) -> (bool, String) {
    match result {
        Ok(payload) => (false, payload),
        Err(error) => {
            let (code, detail) = match error {
                FileError::Canceled => ("canceled", String::new()),
                FileError::NotFound(detail) => ("not-found", detail),
                FileError::PermissionDenied(detail) => ("permission-denied", detail),
                FileError::InvalidUtf8(detail) => ("invalid-utf8", detail),
                FileError::InvalidPath(detail) => ("invalid-path", detail),
                FileError::ResourceLimit(detail) => ("resource-limit", detail),
                FileError::Io(detail) => ("io", detail),
                FileError::Unavailable(detail) => ("unavailable", detail),
            };
            (true, packet(&[code, &file_io::bounded_detail(detail)]))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An absolute directory under the host operating system's path rules.
    const ABSOLUTE_DIRECTORY: &str = if cfg!(windows) { "C:\\tmp" } else { "/tmp" };

    #[test]
    fn new_task_routes_and_cursor_frames_are_strict_and_unambiguous() {
        assert_eq!(
            Request::decode(7, &packet(&["/tmp"])).unwrap(),
            Request::ListDirectory("/tmp".into())
        );
        assert_eq!(
            Request::decode(8, &packet(&["/tmp/file"])).unwrap(),
            Request::OpenPath("/tmp/file".into())
        );
        assert_eq!(
            Request::decode(9, &packet(&["/tmp/file"])).unwrap(),
            Request::ReadPreview("/tmp/file".into())
        );
        assert_eq!(
            Request::decode(
                10,
                &packet(&["/tmp/log", "after", "1", "2", "18446744073709551615"])
            )
            .unwrap(),
            Request::ReadLog {
                path: "/tmp/log".into(),
                position: LogPosition::After(LogCursor {
                    device: 1,
                    inode: 2,
                    offset: u64::MAX
                })
            }
        );
        for fields in [
            vec!["/tmp/log", "start", "1", "0", "0"],
            vec!["/tmp/log", "after", "01", "0", "0"],
            vec!["/tmp/log", "after", "0", "0", "18446744073709551616"],
            vec!["/tmp/log", "middle", "0", "0", "0"],
            vec!["/tmp/log", "end", "0", "0"],
        ] {
            assert!(Request::decode(10, &packet(&fields)).is_err());
        }
        let chunk = file_io::LogChunk {
            path: "/tmp/log".into(),
            text: "λ\n".into(),
            cursor: LogCursor {
                device: 7,
                inode: 13,
                offset: 3,
            },
            change: LogChange::Rotated,
            state: LogState::PartialUtf8,
        };
        assert_eq!(
            log_packet(chunk),
            packet(&["/tmp/log", "λ\n", "7", "13", "3", "rotated", "partial-utf8"])
        );
    }

    #[test]
    fn maximum_request_name_returns_a_bounded_typed_refusal() {
        let name = "x".repeat(MAX_PACKET - 22 - ABSOLUTE_DIRECTORY.len());
        let request = packet(&["at", ABSOLUTE_DIRECTORY, &name]);
        assert_eq!(request.len(), MAX_PACKET);
        let Request::ChooseSavePath { suggested_name, .. } = Request::decode(3, &request).unwrap()
        else {
            panic!("wrong request kind")
        };
        let error = validate_save_options(ABSOLUTE_DIRECTORY, &suggested_name).unwrap_err();
        assert_eq!(
            encode_result(Err(error)),
            (
                true,
                packet(&[
                    "invalid-path",
                    "suggested file name exceeds 255 UTF-8 bytes"
                ])
            )
        );
    }

    #[test]
    fn error_detail_limits_preserve_codes_and_mark_utf8_truncation() {
        let detail = format!("{}λ{}", "x".repeat(4083), "é".repeat(MAX_PACKET / 2));
        for (constructor, code) in [
            (FileError::NotFound as fn(String) -> FileError, "not-found"),
            (FileError::PermissionDenied, "permission-denied"),
            (FileError::InvalidUtf8, "invalid-utf8"),
            (FileError::InvalidPath, "invalid-path"),
            (FileError::ResourceLimit, "resource-limit"),
            (FileError::Io, "io"),
            (FileError::Unavailable, "unavailable"),
        ] {
            let (failed, payload) = encode_result(Err(constructor(detail.clone())));
            assert!(failed);
            let mut reader = Reader(&payload);
            assert_eq!(reader.frame().unwrap(), "files1");
            assert_eq!(reader.frame().unwrap(), code);
            let encoded_detail = reader.frame().unwrap();
            assert_eq!(encoded_detail, format!("{} [truncated]", "x".repeat(4083)));
            assert!(encoded_detail.len() <= file_io::MAX_ERROR_DETAIL_BYTES);
            assert!(reader.0.is_empty());
        }
        assert_eq!(
            encode_result(Err(FileError::Io("ordinary failure".into()))),
            (true, packet(&["io", "ordinary failure"]))
        );
    }

    #[test]
    fn frames_preserve_utf8_newlines_colons_and_empty_text() {
        let path = "/tmp/a:b\nλ.txt";
        let text = "first\nsecond:\0λ";
        assert_eq!(
            Request::decode(5, &packet(&[path, text])).unwrap(),
            Request::WriteText {
                path: path.into(),
                text: text.into()
            }
        );
        assert_eq!(
            Request::decode(5, &packet(&[path, ""])).unwrap(),
            Request::WriteText {
                path: path.into(),
                text: "".into()
            }
        );
    }

    #[test]
    fn request_codec_rejects_malformed_and_wrong_shape_packets() {
        for bad in [
            "",
            "06:files1",
            "6:files1",
            "6:files12:λx",
            "6:files11:λ",
            "6:files15:shorter",
            "6:files1+1:x",
        ] {
            assert!(Request::decode(4, bad).is_err(), "accepted {bad:?}");
        }
        assert!(Request::decode(0, &packet(&[])).is_err());
        assert!(Request::decode(1, &packet(&["extra"])).is_err());
        assert!(Request::decode(5, &packet(&["/tmp/path"])).is_err());
    }

    #[test]
    fn chooser_cancellation_and_explicit_cancellation_are_distinct() {
        assert_eq!(choice(None).unwrap(), packet(&["canceled"]));
        let cancel = AtomicBool::new(true);
        assert_eq!(
            settle(choice(None), &cancel),
            (true, packet(&["canceled", ""]))
        );
        assert!(validate_save_options("/tmp", "../escape").is_err());
        assert!(validate_save_options("relative", "note.txt").is_err());
        assert_eq!(
            Request::decode(3, &packet(&["home", "", "note.txt"])).unwrap(),
            Request::ChooseSavePath {
                directory: Directory::Home,
                suggested_name: "note.txt".into()
            }
        );
        assert!(Request::decode(3, &packet(&["home", "/tmp", "note.txt"])).is_err());
        assert_eq!(
            Request::decode(3, &packet(&["at", "/tmp", "note.txt"])).unwrap(),
            Request::ChooseSavePath {
                directory: Directory::At("/tmp".into()),
                suggested_name: "note.txt".into()
            }
        );
    }
}
