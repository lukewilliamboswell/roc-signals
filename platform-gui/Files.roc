import Action exposing [Action]
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

valid_sha256 : Str -> Bool
valid_sha256 = |digest| {
	bytes = digest.to_utf8()
	bytes.len() == 64 and bytes.fold(True, |ok, byte| ok and ((byte >= 48 and byte <= 57) or (byte >= 97 and byte <= 102)))
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
	if $end == bytes.len() {
		crash "malformed Files frame length"
	}
	count = number(utf8(bytes.take_first($end)))
	start = $end + 1
	if count > bytes.len() - start {
		crash "truncated Files frame"
	}
	{ value: utf8(bytes.drop_first(start).take_first(count)), rest: bytes.drop_first(start + count) }
}

reader : Str -> List(U8)
reader = |payload| {
	bytes = payload.to_utf8()
	if bytes.len() > 8388608 {
		crash "Files payload limit exceeded"
	}
	version = read_frame(bytes)
	if version.value != "files1" {
		crash "unsupported Files payload version"
	}
	version.rest
}

finish : List(U8) -> {}
finish = |rest| {
	if !rest.is_empty() {
		crash "unexpected Files payload fields"
	}
	{}
}

## Native file dialogs and bounded filesystem work as effectful functions,
## called from an action's effect. Paths are absolute UTF-8 strings of at most
## 4096 bytes. A chooser blocks the effect until the user answers; at most 16
## native operations may be retained, and saturation returns ResourceLimit.
Files := [].{
	Choice := [Canceled, Chosen(Str)].{
		is_eq : _
	}
	Error := [
		Canceled,
		NotFound(Str),
		PermissionDenied(Str),
		InvalidUtf8(Str),
		InvalidPath(Str),
		ResourceLimit(Str),
		Io(Str),
		Unavailable(Str),
	].{
		is_eq : _
	}
	Kind := [File, Directory, SymbolicLink, Other].{
		is_eq : _
	}
	TextFile : { path : Str, text : Str }
	Written : { path : Str, bytes : U64 }
	Entry : { path : Str, kind : Kind, bytes : U64 }
	Scan : { root : Str, entries : List(Entry) }
	Directory : { path : Str, entries : List(Entry) }
	Opened : { path : Str }
	Preview : { path : Str, text : Str, truncated : Bool }
	LogCursor : { device : U64, inode : U64, offset : U64 }
	LogPosition := [Start, End, After(LogCursor)].{
		is_eq : _
	}
	LogChange := [Initial, Continued, Rotated, Truncated].{
		is_eq : _
	}
	LogState := [More, AtEnd, PartialUtf8].{
		is_eq : _
	}
	LogChunk : { path : Str, text : Str, cursor : LogCursor, change : LogChange, state : LogState }

	## Hosted: run one filesystem request to completion and return its result
	## packet; `failed` selects the error decoder. Callable only from an effect.
	run! : U32, Str => { failed : Bool, text : Str }

	## Read a complete UTF-8 file of at most one MiB.
	read_text! : Str => Try(TextFile, Error)
	read_text! = |path| call!(Node.TaskKind.ReadText, [path], decode_text)

	## Write the text through a temporary file and an atomic rename; at most one
	## MiB. Replacement is atomic, but parent-directory durability across power
	## loss is not guaranteed.
	write_text! : { path : Str, text : Str } => Try(Written, Error)
	write_text! = |file| call!(Node.TaskKind.WriteText, [file.path, file.text], decode_written)

	## Scan a folder recursively: at most 10,000 entries and 64 levels, symlinks
	## reported but never traversed, four MiB of paths including the root.
	scan! : Str => Try(Scan, Error)
	scan! = |root| call!(Node.TaskKind.ScanDirectory, [root], decode_scan)

	## List a folder's direct children.
	list_directory! : Str => Try(Directory, Error)
	list_directory! = |path| call!(Node.TaskKind.ListDirectory, [path], decode_directory)

	## Hand a regular file to its associated application.
	open_path! : Str => Try(Opened, Error)
	open_path! = |path| call!(Node.TaskKind.OpenPath, [path], decode_opened)

	## Read a bounded text preview; the result reports truncation.
	read_preview! : Str => Try(Preview, Error)
	read_preview! = |path| call!(Node.TaskKind.ReadPreview, [path], decode_preview)

	## Read the next chunk of a log from a cursor, observing rotation and
	## truncation; the cursor is app-owned data.
	read_log! : { path : Str, position : LogPosition } => Try(LogChunk, Error)
	read_log! = |request| {
		fields = match request.position {
			LogPosition.Start => ["start", "0", "0", "0"]
			LogPosition.End => ["end", "0", "0", "0"]
			LogPosition.After(cursor) => ["after", cursor.device.to_str(), cursor.inode.to_str(), cursor.offset.to_str()]
		}
		call!(Node.TaskKind.ReadLog, [request.path].concat(fields), decode_log)
	}

	## Verify a manifest of 1 to 256 assets against the host's assets root.
	verify_assets! : List(AssetEntry) => Try(List(AssetCheck), Error)
	verify_assets! = |entries| call!(Node.TaskKind.VerifyAssets, asset_fields(entries), decode_asset_report)

	call! : Node.TaskKind, List(Str), (Str -> a) => Try(a, Error)
	call! = |kind, fields, decode| {
		result = Files.run!(kind_id(kind), packet(fields))
		if result.failed {
			Err(decode_error(result.text))
		} else {
			Ok(decode(result.text))
		}
	}

	# Protocol ids from protocol/native-protocol.json; the host's decoder
	# selects the request shape by this number.
	kind_id : Node.TaskKind -> U32
	kind_id = |kind| match kind {
		External => 0
		ChooseFile => 1
		ChooseDirectory => 2
		ChooseSavePath => 3
		ReadText => 4
		WriteText => 5
		ScanDirectory => 6
		ListDirectory => 7
		OpenPath => 8
		ReadPreview => 9
		ReadLog => 10
		VerifyAssets => 11
	}

	asset_fields : List(AssetEntry) -> List(Str)
	asset_fields = |entries| {
		if entries.is_empty() or entries.len() > 256 {
			crash "Files asset manifests contain 1 to 256 entries"
		}
		entries.fold(
			[entries.len().to_str()],
			|acc, entry| {
				if entry.name.is_empty() or entry.name.to_utf8().len() > 1024 {
					crash "Files asset names contain 1 to 1024 UTF-8 bytes"
				}
				if !valid_sha256(entry.sha256) {
					crash "Files asset digests are 64 lowercase hex characters"
				}
				acc.append(entry.name).append(entry.sha256)
			},
		)
	}

	## Open the platform's single-file chooser and wait for the user's answer.
	## Dismissing the dialog is the successful `Canceled` choice.
	choose_file! : () => Try(Choice, Error)
	choose_file! = || call!(Node.TaskKind.ChooseFile, [], decode_choice)

	## Open the platform's single-folder chooser and wait for the user's answer.
	choose_directory! : () => Try(Choice, Error)
	choose_directory! = || call!(Node.TaskKind.ChooseDirectory, [], decode_choice)

	## Ask for a save path at the user's home or an absolute initial directory
	## and wait for the user's answer. Home returns Unavailable if the native
	## environment has no UTF-8 HOME value. The suggestion is one nonempty file
	## name of at most 255 UTF-8 bytes.
	choose_save_path! : { directory : [Home, At(Str)], suggested_name : Str } => Try(Choice, Error)
	choose_save_path! = |options| {
		location = match options.directory {
			Home => ["home", ""]
			At(path) => ["at", path]
		}
		call!(Node.TaskKind.ChooseSavePath, location.append(options.suggested_name), decode_choice)
	}

	AssetStatus := [Ok, Missing, Mismatch].{
		is_eq : _
	}
	AssetEntry : { name : Str, sha256 : Str }
	AssetCheck : { name : Str, status : AssetStatus }

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
		if text.value.to_utf8().len() > 1048576 {
			crash "Files text result limit exceeded"
		}
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
		if total > 10000 {
			crash "Files scan result limit exceeded"
		}
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

	decode_directory = |payload| {
		scan_result = decode_scan(payload)
		{ path: scan_result.root, entries: scan_result.entries }
	}

	decode_opened = |payload| {
		path = read_frame(reader(payload))
		finish(path.rest)
		{ path: path.value }
	}

	decode_preview = |payload| {
		path = read_frame(reader(payload))
		text = read_frame(path.rest)
		truncated = read_frame(text.rest)
		finish(truncated.rest)
		if text.value.to_utf8().len() > 65536 {
			crash "Files preview result limit exceeded"
		}
		{
			path: path.value,
			text: text.value,
			truncated: match truncated.value {
				"true" => True
				"false" => False
				_ => crash "malformed Files preview truncation"
			},
		}
	}

	decode_log = |payload| {
		path = read_frame(reader(payload))
		text = read_frame(path.rest)
		device = read_frame(text.rest)
		inode = read_frame(device.rest)
		offset = read_frame(inode.rest)
		change = read_frame(offset.rest)
		state = read_frame(change.rest)
		finish(state.rest)
		if text.value.to_utf8().len() > 65536 {
			crash "Files log result limit exceeded"
		}
		{
			path: path.value,
			text: text.value,
			cursor: { device: number(device.value), inode: number(inode.value), offset: number(offset.value) },
			change: match change.value {
				"initial" => LogChange.Initial
				"continued" => LogChange.Continued
				"rotated" => LogChange.Rotated
				"truncated" => LogChange.Truncated
				_ => crash "malformed Files log change"
			},
			state: match state.value {
				"more" => LogState.More
				"at-end" => LogState.AtEnd
				"partial-utf8" => LogState.PartialUtf8
				_ => crash "malformed Files log state"
			},
		}
	}

	decode_asset_report = |payload| {
		count = read_frame(reader(payload))
		total = number(count.value)
		if total == 0 or total > 256 {
			crash "Files asset report limit exceeded"
		}
		var $rest = count.rest
		var $checks = []
		var $index = 0.U64
		while $index < total {
			name = read_frame($rest)
			status = read_frame(name.rest)
			$checks = $checks.append({
				name: name.value,
				status: match status.value {
					"ok" => AssetStatus.Ok
					"missing" => AssetStatus.Missing
					"mismatch" => AssetStatus.Mismatch
					_ => crash "malformed Files asset status"
				},
			})
			$rest = status.rest
			$index = $index + 1
		}
		finish($rest)
		$checks
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
expect Files.decode_asset_report(packet(["2", "avatars/maya.png", "ok", "glyphs/λ.png", "missing"])) == [{ name: "avatars/maya.png", status: Files.AssetStatus.Ok }, { name: "glyphs/λ.png", status: Files.AssetStatus.Missing }]

expect Files.decode_directory(packet(["/tmp", "1", "/tmp/child", "directory", "0"])) == { path: "/tmp", entries: [{ path: "/tmp/child", kind: Files.Kind.Directory, bytes: 0 }] }
expect Files.decode_opened(packet(["/tmp/a:λ.txt"])) == { path: "/tmp/a:λ.txt" }
expect Files.decode_preview(packet(["/tmp/text", "first\nλ", "true"])) == { path: "/tmp/text", text: "first\nλ", truncated: True }
expect Files.decode_log(packet(["/tmp/log", "λ\n", "7", "13", "3", "rotated", "partial-utf8"])) == { path: "/tmp/log", text: "λ\n", cursor: { device: 7, inode: 13, offset: 3 }, change: Files.LogChange.Rotated, state: Files.LogState.PartialUtf8 }
