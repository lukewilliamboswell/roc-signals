import Node
import Signal

# A private, bounded sequence of UTF-8 frames: decimal byte length, colon, data.
# The first frame is the codec version; result shape belongs to the task kind.
frame : Str -> Str
frame = |value| "${value.to_utf8().len().to_str()}:${value}"

packet : List(Str) -> Str
packet = |fields| Str.join_with(["files1"].concat(fields).map(frame), "")

utf8 : List(U8) -> Str
utf8 = |bytes| match Str.from_utf8(bytes) {
	Ok(value) => value
	Err(_) => crash "malformed Files UTF-8 frame"
}

number : Str -> U64
number = |text| match U64.from_str(text) {
	Ok(value) if value.to_str() == text => value
	_ => crash "malformed Files unsigned number"
}

read_frame : List(U8) -> { value : Str, rest : List(U8) }
read_frame = |bytes| {
	var $end = 0.U64
	while $end < bytes.len() and bytes.get($end) != Ok(58) {
		$end = $end + 1
	}
	if $end == bytes.len() { crash "malformed Files frame length" }
	count = number(utf8(bytes.take_first($end)))
	start = $end + 1
	if count > bytes.len() - start { crash "truncated Files frame" }
	{ value: utf8(bytes.drop_first(start).take_first(count)), rest: bytes.drop_first(start + count) }
}

reader : Str -> List(U8)
reader = |payload| {
	bytes = payload.to_utf8()
	if bytes.len() > 8388608 { crash "Files payload limit exceeded" }
	version = read_frame(bytes)
	if version.value != "files1" { crash "unsupported Files payload version" }
	version.rest
}

finish : List(U8) -> {}
finish = |rest| {
	if !rest.is_empty() { crash "unexpected Files payload fields" }
	{}
}

file_task : Node.TaskKind, Str, (Str -> a) -> Signal.Task(a, Files.Error)
	where [a.is_eq : a, a -> Bool]
file_task = |kind, name, decode|
	Signal.host_task_source_with_eq(
		kind,
		{ name, reset_on_start: True, canceled: || Files.Error.Canceled, refused: || Files.Error.ResourceLimit("native task capacity is full") },
		decode,
		Files.decode_error,
		|left, right| left.is_eq(right),
		|left, right| left == right,
	)

file_start : Node.TaskKind, Signal.Task(a, Files.Error), List(Str) -> Node.Cmd
file_start = |kind, task, fields| {
	if task.source.kind != kind { crash "Files command used a different task kind" }
	Signal.start_str(task, packet(fields))
}

## Native file dialogs and bounded background filesystem work. Paths are absolute
## UTF-8 strings of at most 4096 bytes. Every completion uses the shared task
## signal and scope lifetime. At most 16 native operations, including canceled
## workers awaiting completion, may be retained; saturation returns ResourceLimit.
Files := [].{
	Choice := [Canceled, Chosen(Str)].{ is_eq : _ }
	Error := [
		Canceled,
		NotFound(Str),
		PermissionDenied(Str),
		InvalidUtf8(Str),
		InvalidPath(Str),
		ResourceLimit(Str),
		Io(Str),
		Unavailable(Str),
	].{ is_eq : _ }
	Kind := [File, Directory, SymbolicLink, Other].{ is_eq : _ }
	TextFile : { path : Str, text : Str }
	Written : { path : Str, bytes : U64 }
	Entry : { path : Str, kind : Kind, bytes : U64 }
	Scan : { root : Str, entries : List(Entry) }

	## Create one file-choice task. The label is diagnostic and never routes work.
	choose_file_task : Str -> Signal.Task(Choice, Error)
	choose_file_task = |name| file_task(Node.TaskKind.ChooseFile, name, decode_choice)

	## Create one folder-choice task.
	choose_directory_task : Str -> Signal.Task(Choice, Error)
	choose_directory_task = |name| file_task(Node.TaskKind.ChooseDirectory, name, decode_choice)

	## Create one save-destination task. Dialog cancellation is a successful Choice.
	choose_save_path_task : Str -> Signal.Task(Choice, Error)
	choose_save_path_task = |name| file_task(Node.TaskKind.ChooseSavePath, name, decode_choice)

	## Open the platform's single-file chooser.
	choose_file : Signal.Task(Choice, Error) -> Node.Cmd
	choose_file = |task| file_start(Node.TaskKind.ChooseFile, task, [])

	## Open the platform's single-folder chooser.
	choose_directory : Signal.Task(Choice, Error) -> Node.Cmd
	choose_directory = |task| file_start(Node.TaskKind.ChooseDirectory, task, [])

	## Ask for a save path at the user's home or an absolute initial directory.
	## Home returns Unavailable if the native environment has no UTF-8 HOME value.
	choose_save_path : Signal.Task(Choice, Error), { directory : [Home, At(Str)], suggested_name : Str } -> Node.Cmd
	choose_save_path = |task, options| {
		location = match options.directory {
			Home => ["home", ""]
			At(path) => ["at", path]
		}
		file_start(Node.TaskKind.ChooseSavePath, task, location.append(options.suggested_name))
	}

	## Create a task for strict UTF-8 files of at most one MiB.
	read_text_task : Str -> Signal.Task(TextFile, Error)
	read_text_task = |name| file_task(Node.TaskKind.ReadText, name, decode_text)

	## Read a complete file without publishing partial contents.
	read_text : Signal.Task(TextFile, Error), Str -> Node.Cmd
	read_text = |task, path| file_start(Node.TaskKind.ReadText, task, [path])

	## Create a task that writes at most one MiB through a temporary file + rename.
	write_text_task : Str -> Signal.Task(Written, Error)
	write_text_task = |name| file_task(Node.TaskKind.WriteText, name, decode_written)

	## Save the submitted immutable text. Cancellation cannot undo a committed rename.
	write_text : Signal.Task(Written, Error), { path : Str, text : Str } -> Node.Cmd
	write_text = |task, file| file_start(Node.TaskKind.WriteText, task, [file.path, file.text])

	## Create a recursive folder scan: at most 10,000 entries and 64 levels.
	## Symlinks and other entries are reported; symlinks are never traversed.
	## Aggregate entry paths are bounded at four MiB; limits refuse the whole scan.
	scan_task : Str -> Signal.Task(Scan, Error)
	scan_task = |name| file_task(Node.TaskKind.ScanDirectory, name, decode_scan)

	## Publish one complete metadata snapshot, or a typed error without truncation.
	scan : Signal.Task(Scan, Error), Str -> Node.Cmd
	scan = |task, root| file_start(Node.TaskKind.ScanDirectory, task, [root])

	## Describe a native failure without losing its typed case.
	error_text : Error -> Str
	error_text = |error| match error {
		Canceled => "Canceled"
		NotFound(path) => "Not found: ${path}"
		PermissionDenied(path) => "Permission denied: ${path}"
		InvalidUtf8(path) => "Not valid UTF-8: ${path}"
		InvalidPath(path) => "Invalid path: ${path}"
		ResourceLimit(detail) => "Resource limit: ${detail}"
		Io(detail) => "File operation failed: ${detail}"
		Unavailable(detail) => "Native service unavailable: ${detail}"
	}

	decode_choice = |payload| {
		kind = read_frame(reader(payload))
		match kind.value {
			"canceled" => {
				finish(kind.rest)
				Choice.Canceled
			}
			"chosen" => {
				path = read_frame(kind.rest)
				finish(path.rest)
				Choice.Chosen(path.value)
			}
			_ => crash "malformed Files choice"
		}
	}

	decode_text = |payload| {
		path = read_frame(reader(payload))
		text = read_frame(path.rest)
		finish(text.rest)
		if text.value.to_utf8().len() > 1048576 { crash "Files text result limit exceeded" }
		{ path: path.value, text: text.value }
	}

	decode_written = |payload| {
		path = read_frame(reader(payload))
		bytes = read_frame(path.rest)
		finish(bytes.rest)
		{ path: path.value, bytes: number(bytes.value) }
	}

	decode_scan = |payload| {
		root = read_frame(reader(payload))
		count = read_frame(root.rest)
		total = number(count.value)
		if total > 10000 { crash "Files scan result limit exceeded" }
		var $rest = count.rest
		var $entries = []
		var $index = 0.U64
		while $index < total {
			path = read_frame($rest)
			kind = read_frame(path.rest)
			bytes = read_frame(kind.rest)
			entry_kind = match kind.value {
				"file" => Kind.File
				"directory" => Kind.Directory
				"symbolic-link" => Kind.SymbolicLink
				"other" => Kind.Other
				_ => crash "malformed Files entry kind"
			}
			$entries = $entries.append({ path: path.value, kind: entry_kind, bytes: number(bytes.value) })
			$rest = bytes.rest
			$index = $index + 1
		}
		finish($rest)
		{ root: root.value, entries: $entries }
	}

	decode_error = |payload| {
		kind = read_frame(reader(payload))
		detail = read_frame(kind.rest)
		finish(detail.rest)
		match kind.value {
			"canceled" if detail.value == "" => Error.Canceled
			"not-found" => Error.NotFound(detail.value)
			"permission-denied" => Error.PermissionDenied(detail.value)
			"invalid-utf8" => Error.InvalidUtf8(detail.value)
			"invalid-path" => Error.InvalidPath(detail.value)
			"resource-limit" => Error.ResourceLimit(detail.value)
			"io" => Error.Io(detail.value)
			"unavailable" => Error.Unavailable(detail.value)
			_ => crash "malformed Files error kind"
		}
	}
}

## Frames preserve separators, line breaks, non-ASCII text, and empty content.
expect Files.decode_text(packet(["/tmp/a:b\nλ.txt", "first\nsecond: λ"])) == { path: "/tmp/a:b\nλ.txt", text: "first\nsecond: λ" }
expect Files.decode_choice(packet(["canceled"])) == Files.Choice.Canceled
expect Files.decode_written(packet(["/tmp/empty", "0"])) == { path: "/tmp/empty", bytes: 0 }
expect Files.decode_scan(packet(["/tmp", "1", "/tmp/link", "symbolic-link", "0"])) == { root: "/tmp", entries: [{ path: "/tmp/link", kind: Files.Kind.SymbolicLink, bytes: 0 }] }
