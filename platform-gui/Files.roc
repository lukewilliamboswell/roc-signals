## Native filesystem and dialog primitives as effectful functions, called from
## an action's effect, and the conveniences the platform builds on them in
## Roc. Paths are absolute UTF-8 strings of at most 4096 bytes; the host never
## follows a symbolic link, in a path or as a target. A chooser blocks the
## effect until the user answers.
## Paths are spelled by the operating system the host runs on: a Windows
## worker returns drive-rooted paths written with backslashes. Derive any
## parent, name, root, or breadcrumb through `Files.parse_path` and the
## `Files.Path` queries rather than by splitting a path string on one separator.
utf8 : List(U8) -> Str
utf8 = |bytes| match Str.from_utf8(bytes) {
	Ok(value) => value
	Err(_) => crash "malformed Files UTF-8 frame"
}

# Lexical path primitives shared by the Files.Path methods. Every one works on
# UTF-8 bytes and cuts only at ASCII separators, so a slice never splits a code
# point. None of them inspects or rewrites a byte outside its own path style.
path_byte : List(U8), U64 -> U8
path_byte = |bytes, index| bytes.get(index) ?? 0

is_path_separator : Files.PathStyle, U8 -> Bool
is_path_separator = |style, byte| match style {
	Posix => byte == 47
	Windows => byte == 47 or byte == 92
}

is_drive_letter : U8 -> Bool
is_drive_letter = |byte| (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122)

is_unc_prefix : List(U8) -> Bool
is_unc_prefix = |bytes| bytes.get(0) == Ok(92) and bytes.get(1) == Ok(92)

is_drive_prefix : List(U8) -> Bool
is_drive_prefix = |bytes| is_drive_letter(path_byte(bytes, 0)) and bytes.get(1) == Ok(58)

path_style : Str -> Files.PathStyle
path_style = |text| {
	bytes = text.to_utf8()
	if is_unc_prefix(bytes) or is_drive_prefix(bytes) {
		Files.PathStyle.Windows
	} else {
		Files.PathStyle.Posix
	}
}

path_scan : List(U8), U64, Files.PathStyle -> U64
path_scan = |bytes, from, style| {
	var $index = from
	while $index < bytes.len() and !is_path_separator(style, path_byte(bytes, $index)) {
		$index = $index + 1
	}
	$index
}

# The root prefix length in bytes, including one trailing separator when the
# path spells it. A relative path has a zero-length root.
path_root_len : List(U8), Files.PathStyle -> U64
path_root_len = |bytes, style| {
	leading = if is_path_separator(style, path_byte(bytes, 0)) {
		1
	} else {
		0
	}
	match style {
		Posix => leading
		Windows =>
			if is_unc_prefix(bytes) {
				host_end = path_scan(bytes, 2, style)
				share_end = if host_end < bytes.len() {
					path_scan(bytes, host_end + 1, style)
				} else {
					host_end
				}
				if share_end < bytes.len() {
					share_end + 1
				} else {
					share_end
				}
			} else if is_drive_prefix(bytes) {
				if is_path_separator(style, path_byte(bytes, 2)) {
					3
				} else {
					2
				}
			} else {
				leading
			}
	}
}

# The end of the path's components: `limit` with any trailing separator run
# removed, never cutting into the root.
path_content_end : List(U8), Files.PathStyle, U64, U64 -> U64
path_content_end = |bytes, style, root_len, limit| {
	var $end = limit
	while $end > root_len and is_path_separator(style, path_byte(bytes, $end - 1)) {
		$end = $end - 1
	}
	$end
}

path_last_separator : List(U8), Files.PathStyle, U64, U64 -> [NoSeparator, At(U64)]
path_last_separator = |bytes, style, root_len, end| {
	var $index = end
	var $result = NoSeparator
	while $index > root_len and $result == NoSeparator {
		$index = $index - 1
		if is_path_separator(style, path_byte(bytes, $index)) {
			$result = At($index)
		}
	}
	$result
}

path_slice : List(U8), U64, U64 -> Str
path_slice = |bytes, from, to| utf8(bytes.drop_first(from).take_first(to - from))
Files := [].{
	Choice := [Canceled, Chosen(Str)].{
		is_eq : _
	}
	Error := [
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
	Metadata : { kind : Kind, bytes : U64, device : U64, inode : U64 }
	Read : { bytes : List(U8), size : U64 }
	Entry : { path : Str, kind : Kind, bytes : U64 }
	Directory : { path : Str, entries : List(Entry) }
	SaveOptions : { directory : [Home, At(Str)], suggested_name : Str }

	## Open the platform's single-file chooser and wait for the user's answer.
	## Dismissing the dialog is the successful `Canceled` choice.
	choose_file! : () => Try(Choice, Error)

	## Open the platform's single-folder chooser and wait for the user's answer.
	choose_directory! : () => Try(Choice, Error)

	## Ask for a save path at the user's home or an absolute initial directory
	## and wait for the user's answer. Home returns Unavailable if the native
	## environment has no UTF-8 HOME value. The suggestion is one nonempty file
	## name of at most 255 UTF-8 bytes.
	choose_save_path! : SaveOptions => Try(Choice, Error)

	## Metadata of the entry at a path without following a symbolic link.
	stat! : Str => Try(Metadata, Error)

	## Read at most `max_bytes` bytes of a regular file starting at `offset`,
	## with the file's size at that moment.
	read_bytes! : { path : Str, offset : U64, max_bytes : U64 } => Try(Read, Error)

	## Create or replace a regular file with the bytes.
	write_bytes! : { path : Str, bytes : List(U8) } => Try({}, Error)

	## Rename an entry, replacing any regular file at the destination.
	rename! : { from : Str, to : Str } => Try({}, Error)

	## Remove a regular file or an empty directory.
	remove! : Str => Try({}, Error)

	## Flush a regular file's contents to durable storage.
	sync! : Str => Try({}, Error)

	## List a folder's direct children, sorted by path.
	list_directory! : Str => Try(Directory, Error)

	## Hand a regular file to its associated application.
	open_path! : Str => Try({}, Error)

	## The folder the host resolves relative asset sources against.
	assets_root! : () => Str


	## How one path spells its root and separators. A native worker returns the
	## operating system's own spelling, so both cases reach the same application.
	PathStyle := [Posix, Windows].{
		is_eq : _
	}

	## One native path, carrying the spelling it was recognized as.
	##
	## `Files.path` classifies a path once, by shape, at the boundary where it
	## enters the application; nothing below ever rewrites a separator byte.
	## A Posix path separates only on `/`, so a backslash inside a Unix file
	## name stays part of that name. A Windows path separates on `\` or `/`.
	##
	## `text` is exactly the bytes the host supplied. Every query here is lexical:
	## it consults no filesystem, resolves no link, and never normalizes `.`/`..`.
	## Redundant separators are ignored when locating a component, and a trailing
	## separator never produces an empty final component.
	Path := { text : Str, style : PathStyle }.{
		is_eq : _

		## The exact path bytes, suitable for a native request or for identity.
		to_str : Path -> Str
		to_str = |value| value.text

		## The root prefix: `/`, `C:\`, `\\server\share\`, or empty when relative.
		## A root is a path in the same style, so it can be joined onto directly.
		root : Path -> Path
		root = |value| {
			bytes = value.text.to_utf8()
			Path.{ text: path_slice(bytes, 0, path_root_len(bytes, value.style)), style: value.style }
		}

		## True when the path holds no component above its root, so `parent`
		## can no longer make progress. The empty relative path qualifies.
		is_root : Path -> Bool
		is_root = |value| {
			bytes = value.text.to_utf8()
			root_len = path_root_len(bytes, value.style)
			path_content_end(bytes, value.style, root_len, bytes.len()) <= root_len
		}

		## The final component. A root is its own name, so `/` names `/` and
		## `C:\` names `C:\`; a trailing separator is ignored.
		name : Path -> Str
		name = |value| {
			bytes = value.text.to_utf8()
			root_len = path_root_len(bytes, value.style)
			end = path_content_end(bytes, value.style, root_len, bytes.len())
			if end <= root_len {
				path_slice(bytes, 0, root_len)
			} else {
				match path_last_separator(bytes, value.style, root_len, end) {
					NoSeparator => path_slice(bytes, root_len, end)
					At(index) => path_slice(bytes, index + 1, end)
				}
			}
		}

		## The lexical parent. Every root is its own parent, so repeatedly taking
		## a parent terminates; a one-component relative path yields the empty
		## relative path rather than inventing an absolute root.
		parent : Path -> Path
		parent = |value| {
			bytes = value.text.to_utf8()
			root_len = path_root_len(bytes, value.style)
			end = path_content_end(bytes, value.style, root_len, bytes.len())
			if end <= root_len {
				value
			} else {
				cut = match path_last_separator(bytes, value.style, root_len, end) {
					NoSeparator => root_len
					At(index) => path_content_end(bytes, value.style, root_len, index)
				}
				Path.{ text: path_slice(bytes, 0, cut), style: value.style }
			}
		}

		## The same location with any trailing separator run removed, so a path
		## used as a prefix ends exactly one separator before its children. A
		## root keeps the separator that is part of the root itself.
		trimmed : Path -> Path
		trimmed = |value| {
			bytes = value.text.to_utf8()
			root_len = path_root_len(bytes, value.style)
			end = path_content_end(bytes, value.style, root_len, bytes.len())
			Path.{ text: path_slice(bytes, 0, end), style: value.style }
		}

		## The components above the root, in order. Empty separator runs and a
		## trailing separator contribute no component.
		components : Path -> List(Str)
		components = |value| {
			bytes = value.text.to_utf8()
			style = value.style
			root_len = path_root_len(bytes, style)
			end = path_content_end(bytes, style, root_len, bytes.len())
			var $parts = []
			var $start = root_len
			var $index = root_len
			while $index < end {
				if is_path_separator(style, path_byte(bytes, $index)) {
					if $index > $start {
						$parts = $parts.append(path_slice(bytes, $start, $index))
					}
					$start = $index + 1
				}
				$index = $index + 1
			}
			if end > $start {
				$parts = $parts.append(path_slice(bytes, $start, end))
			}
			$parts
		}

		## Append one component using this path's own primary separator, adding
		## one only where the path does not already end in a separator.
		join : Path, Str -> Path
		join = |value, child| {
			separator = match value.style {
				Posix => "/"
				Windows => "\\"
			}
			bytes = value.text.to_utf8()
			joined = if bytes.is_empty() {
				child
			} else if is_path_separator(value.style, path_byte(bytes, bytes.len() - 1)) {
				"${value.text}${child}"
			} else {
				"${value.text}${separator}${child}"
			}
			Path.{ text: joined, style: value.style }
		}
	}

	## Recognize one native path by shape. A path is Windows-spelled when it
	## begins with a drive designator (`C:`) or a UNC prefix (`\\`); anything
	## else, including a relative path, is Posix-spelled. Bytes are preserved.
	parse_path : Str -> Path
	parse_path = |text| Path.{ text, style: path_style(text) }
	TextFile : { path : Str, text : Str }
	Written : { path : Str, bytes : U64 }
	Scan : { root : Str, entries : List(Entry) }
	Preview : { path : Str, text : Str, truncated : Bool }
	AssetStatus := [Ok, Missing, Mismatch].{
		is_eq : _
	}
	AssetEntry : { name : Str, sha256 : Str }
	AssetCheck : { name : Str, status : AssetStatus }

	max_text_bytes = 1048576
	max_preview_bytes = 65536
	max_scan_entries = 10000
	max_scan_depth = 64
	max_scan_path_bytes = 4194304
	max_asset_bytes = 33554432

	## Read a complete UTF-8 file of at most one MiB.
	read_text! : Str => Try(TextFile, Error)
	read_text! = |path| match Files.read_bytes!({ path, offset: 0, max_bytes: max_text_bytes + 1 }) {
		Err(error) => Err(error)
		Ok(read) => if read.size > max_text_bytes {
			Err(ResourceLimit("${path} exceeds ${max_text_bytes.to_str()} bytes"))
		} else {
			match Str.from_utf8(read.bytes) {
				Ok(text) => Ok({ path, text })
				Err(_) => Err(InvalidUtf8(path))
			}
		}
	}

	## Write text of at most one MiB through a temporary sibling, a flush, and a
	## rename, so the destination is either its old or its new complete content.
	## Parent-directory durability across power loss is not guaranteed.
	write_text! : { path : Str, text : Str } => Try(Written, Error)
	write_text! = |file| {
		bytes = file.text.to_utf8()
		if bytes.len() > max_text_bytes {
			return Err(ResourceLimit("${file.path} exceeds ${max_text_bytes.to_str()} bytes"))
		}
		temporary = "${file.path}.roc-signals-tmp"
		match Files.write_bytes!({ path: temporary, bytes }) {
			Err(error) => Err(error)
			Ok({}) => match Files.sync!(temporary) {
				Err(error) => discard_temporary!(temporary, error)
				Ok({}) => match Files.rename!({ from: temporary, to: file.path }) {
					Err(error) => discard_temporary!(temporary, error)
					Ok({}) => Ok({ path: file.path, bytes: bytes.len() })
				}
			}
		}
	}

	discard_temporary! : Str, Error => Try(Written, Error)
	discard_temporary! = |temporary, error| match Files.remove!(temporary) {
		_ => Err(error)
	}

	## Read a UTF-8 prefix of at most 64 KiB; `truncated` reports omitted bytes,
	## and a code point cut by the bound is excluded.
	read_preview! : Str => Try(Preview, Error)
	read_preview! = |path| match Files.read_bytes!({ path, offset: 0, max_bytes: max_preview_bytes }) {
		Err(error) => Err(error)
		Ok(read) => match utf8_prefix(read.bytes) {
			Err(_) => Err(InvalidUtf8(path))
			Ok(text) => Ok({ path, text, truncated: read.size > read.bytes.len() })
		}
	}

	## The longest prefix that is complete UTF-8; only an incomplete final code
	## point is excluded, and invalid bytes anywhere are refused.
	utf8_prefix : List(U8) -> Try(Str, [InvalidUtf8])
	utf8_prefix = |bytes| utf8_prefix_from(bytes, 0)

	utf8_prefix_from : List(U8), U64 -> Try(Str, [InvalidUtf8])
	utf8_prefix_from = |bytes, dropped| match Str.from_utf8(bytes) {
		Ok(text) => Ok(text)
		Err(_) => match bytes.last() {
			# Only a continuation or lead byte at the end can be an incomplete
			# code point; anything else is invalid content.
			Ok(byte) if ((byte >= 128 and byte <= 191) or (byte >= 194 and byte <= 244)) and dropped < 3 => utf8_prefix_from(bytes.take_first(bytes.len() - 1), dropped + 1)
			_ => Err(InvalidUtf8)
		}
	}

	## Scan a folder recursively: at most 10,000 entries and 64 levels, symbolic
	## links reported but never followed, four MiB of paths including the root.
	scan! : Str => Try(Scan, Error)
	scan! = |root| match scan_into!(root, 0, { entries: [], path_bytes: root.to_utf8().len() }) {
		Err(error) => Err(error)
		Ok(budget) => Ok({ root, entries: budget.entries })
	}

	ScanBudget : { entries : List(Entry), path_bytes : U64 }

	scan_into! : Str, U64, ScanBudget => Try(ScanBudget, Error)
	scan_into! = |path, depth, budget| {
		if depth > max_scan_depth {
			return Err(ResourceLimit("${path} is nested deeper than ${max_scan_depth.to_str()} levels"))
		}
		match Files.list_directory!(path) {
			Err(error) => Err(error)
			Ok(directory) => scan_entries!(directory.entries, depth, budget)
		}
	}

	scan_entries! : List(Entry), U64, ScanBudget => Try(ScanBudget, Error)
	scan_entries! = |entries, depth, budget| match entries.first() {
		Err(_) => Ok(budget)
		Ok(entry) => {
			path_bytes = budget.path_bytes + entry.path.to_utf8().len()
			if budget.entries.len() >= max_scan_entries {
				return Err(ResourceLimit("scan holds more than ${max_scan_entries.to_str()} entries"))
			}
			if path_bytes > max_scan_path_bytes {
				return Err(ResourceLimit("scan holds more than ${max_scan_path_bytes.to_str()} bytes of paths"))
			}
			next = { entries: budget.entries.append(entry), path_bytes }
			descended = if entry.kind == Directory {
				scan_into!(entry.path, depth + 1, next)
			} else {
				Ok(next)
			}
			match descended {
				Err(error) => Err(error)
				Ok(after) => scan_entries!(entries.drop_first(1), depth, after)
			}
		}
	}

	## Verify a manifest of 1 to 256 assets against the host's assets root:
	## each relative name of 1 to 1024 bytes is read and hashed with SHA-256.
	## A missing, unreadable, symbolic-link, or special entry is `Missing`.
	verify_assets! : List(AssetEntry) => Try(List(AssetCheck), Error)
	verify_assets! = |entries| {
		if entries.is_empty() or entries.len() > 256 {
			return Err(InvalidPath("asset manifests contain 1 to 256 entries"))
		}
		verify_each!(Files.assets_root!(), entries, [])
	}

	verify_each! : Str, List(AssetEntry), List(AssetCheck) => Try(List(AssetCheck), Error)
	verify_each! = |root, remaining, checks| match remaining.first() {
		Err(_) => Ok(checks)
		Ok(entry) => match verify_asset!(root, entry) {
			Err(error) => Err(error)
			Ok(status) => verify_each!(root, remaining.drop_first(1), checks.append({ name: entry.name, status }))
		}
	}

	verify_asset! : Str, AssetEntry => Try(AssetStatus, Error)
	verify_asset! = |root, entry| {
		name_bytes = entry.name.to_utf8().len()
		if name_bytes == 0 or name_bytes > 1024 {
			return Err(InvalidPath("asset names contain 1 to 1024 UTF-8 bytes"))
		}
		if entry.name.starts_with("/") or entry.name.contains("\\") or entry.name.split_on("/").contains("..") {
			return Err(InvalidPath("asset names are relative paths without traversal: ${entry.name}"))
		}
		if !valid_sha256(entry.sha256) {
			return Err(InvalidPath("asset digests are 64 lowercase hex characters: ${entry.name}"))
		}
		match Files.read_bytes!({ path: "${root}/${entry.name}", offset: 0, max_bytes: max_asset_bytes + 1 }) {
			Err(NotFound(_)) => Ok(Missing)
			Err(InvalidPath(_)) => Ok(Missing)
			Err(error) => Err(error)
			Ok(read) => if read.size > max_asset_bytes {
				Err(ResourceLimit("${entry.name} exceeds ${max_asset_bytes.to_str()} bytes"))
			} else if Crypto.SHA256.hash(read.bytes).to_hex() == entry.sha256 {
				Ok(Ok)
			} else {
				Ok(Mismatch)
			}
		}
	}

	valid_sha256 : Str -> Bool
	valid_sha256 = |digest| {
		bytes = digest.to_utf8()
		bytes.len() == 64 and bytes.fold(True, |ok, byte| ok and ((byte >= 48 and byte <= 57) or (byte >= 97 and byte <= 102)))
	}

	## Describe a native failure without losing its typed case.
	error_text : Error -> Str
	error_text = |error| match error {
		NotFound(path) => "Not found: ${path}"
		PermissionDenied(path) => "Permission denied: ${path}"
		InvalidUtf8(path) => "Not valid UTF-8: ${path}"
		InvalidPath(path) => "Invalid path: ${path}"
		ResourceLimit(detail) => "Resource limit: ${detail}"
		Io(detail) => "File operation failed: ${detail}"
		Unavailable(detail) => "Native service unavailable: ${detail}"
	}
}

expect Files.utf8_prefix("héllo".to_utf8()) == Ok("héllo")
expect Files.utf8_prefix("hé".to_utf8().take_first(2)) == Ok("h")
expect Files.utf8_prefix([0xff, 0x41]) == Err(InvalidUtf8)
expect Files.valid_sha256("0000000000000000000000000000000000000000000000000000000000000000")
expect !Files.valid_sha256("00000000000000000000000000000000000000000000000000000000000000ZZ")



## A Posix path separates only on `/`, so a backslash is an ordinary character
## in a Unix file name and Unicode segments survive intact.
expect {
	note = Files.parse_path("/tmp/λ dir/a\\b.txt")
	note.name() == "a\\b.txt" and note.parent().to_str() == "/tmp/λ dir" and note.components() == ["tmp", "λ dir", "a\\b.txt"]
}

## The Unix root is its own parent and its own name, and a trailing separator
## never becomes an empty final component.
expect {
	root = Files.parse_path("/")
	trailing = Files.parse_path("/tmp/project/")
	root.is_root() and root.name() == "/" and root.parent().to_str() == "/" and trailing.name() == "project" and trailing.parent().to_str() == "/tmp"
}

## A drive-rooted Windows path yields its final segment, its real parent, and a
## `C:\` root that terminates the parent chain.
expect {
	note = Files.parse_path("C:\\Users\\Lee\\Ideas.txt")
	drive = Files.parse_path("C:\\")
	note.name() == "Ideas.txt" and note.parent().to_str() == "C:\\Users\\Lee" and note.root().to_str() == "C:\\" and drive.is_root() and drive.parent().to_str() == "C:\\"
}

## Windows accepts either separator, and the bytes the host supplied are kept.
expect {
	mixed = Files.parse_path("C:/Users/Lee")
	mixed.name() == "Lee" and mixed.parent().to_str() == "C:/Users" and mixed.to_str() == "C:/Users/Lee"
}

## A UNC share is a root: it terminates the parent chain and contributes no
## component of its own.
expect {
	file = Files.parse_path("\\\\server\\share\\docs\\a.txt")
	share = Files.parse_path("\\\\server\\share")
	file.root().to_str() == "\\\\server\\share\\" and file.components() == ["docs", "a.txt"] and file.parent().to_str() == "\\\\server\\share\\docs" and share.is_root()
}

## A relative path keeps its relative parent instead of inventing a root, and
## `join` adds the style's own separator only where one is missing.
expect {
	relative = Files.parse_path("docs/file.txt")
	relative.parent().to_str() == "docs" and relative.parent().parent().to_str() == "" and Files.parse_path("C:\\").join("Users").to_str() == "C:\\Users" and Files.parse_path("/tmp").join("a").to_str() == "/tmp/a"
}

## Trimming removes a trailing separator run without disturbing a root, so a
## location can be used as an exact prefix of its children.
expect {
	Files.parse_path("/tmp/project///").trimmed().to_str() == "/tmp/project" and
	Files.parse_path("/").trimmed().to_str() == "/" and
	Files.parse_path("C:\\").trimmed().to_str() == "C:\\"
}
