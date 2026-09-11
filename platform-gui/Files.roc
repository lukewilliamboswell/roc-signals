## Native filesystem and dialog primitives as effectful functions, called from
## an action's effect, and the conveniences the platform builds on them in
## Roc. Paths are absolute UTF-8 strings of at most 4096 bytes; the host never
## follows a symbolic link, in a path or as a target. A chooser blocks the
## effect until the user answers.
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
