## Pure presentation and dataset operations for the folder explorer. The native
## file service supplies metadata; filtering and ordering remain ordinary Roc.
Explorer :: [].{
	Kind := [File, Directory].{
		is_eq : _

		to_str : Kind -> Str
		to_str = |kind|
			match kind {
				File => "File"
				Directory => "Folder"
			}
	}

	Entry : { path : Str, kind : Kind, bytes : U64 }

	Sort := [NameAscending, NameDescending, LargestFirst].{
		is_eq : _

		to_str : Sort -> Str
		to_str = |sort|
			match sort {
				NameAscending => "Name A–Z"
				NameDescending => "Name Z–A"
				LargestFirst => "Largest files"
			}
	}

	Selection := [NoSelection, Selected(Entry)].{
		is_eq : _
	}

	Summary : { files : U64, folders : U64, bytes : U128 }

	sorts : List(Sort)
	sorts = [NameAscending, NameDescending, LargestFirst]

	## The starter dataset is explicitly a sample workspace, not a scan of the
	## user's machine. Every path is stable under sorting and filtering.
	sample_entries : List(Entry)
	sample_entries = [
		{ path: "assets", kind: Directory, bytes: 0 },
		{ path: "assets/app-icon.png", kind: File, bytes: 18432 },
		{ path: "assets/welcome.png", kind: File, bytes: 245760 },
		{ path: "docs", kind: Directory, bytes: 0 },
		{ path: "docs/launch-checklist.md", kind: File, bytes: 3584 },
		{ path: "docs/research-notes.md", kind: File, bytes: 12288 },
		{ path: "docs/日本語.md", kind: File, bytes: 2048 },
		{ path: "src", kind: Directory, bytes: 0 },
		{ path: "src/Editor.roc", kind: File, bytes: 16384 },
		{ path: "src/Model.roc", kind: File, bytes: 8192 },
		{ path: "src/main.roc", kind: File, bytes: 4096 },
		{ path: "test", kind: Directory, bytes: 0 },
		{ path: "test/editing.scm", kind: File, bytes: 2048 },
		{ path: "test/navigation.scm", kind: File, bytes: 3072 },
		{ path: "README.md", kind: File, bytes: 1536 },
		{ path: "release-notes.md", kind: File, bytes: 0 },
	]

	filter : List(Entry), Str -> List(Entry)
	filter = |entries, query| {
		needle = search_text(query.trim())
		entries.keep_if(|entry| search_text(entry.path).contains(needle))
	}

	search_text : Str -> Str
	search_text = |text|
		Str.from_utf8(
			text.to_utf8().map(
				|byte| if byte >= 65 and byte <= 90 {
					byte + 32
				} else {
					byte
				},
			),
		) ?? crash "ASCII case folding must preserve UTF-8"

	## Folders precede files in every ordering. Equal file sizes use exact path
	## bytes as a deterministic tie break, independent of source enumeration order.
	sort : List(Entry), Sort -> List(Entry)
	sort = |entries, order| entries.sort_with(|left, right| compare(left, right, order))

	compare : Entry, Entry, Sort -> [Before, Same, After]
	compare = |left, right, order|
		match (left.kind, right.kind) {
			(Directory, File) => Before
			(File, Directory) => After
			_ => match order {
				NameAscending => compare_path(left.path, right.path)
				NameDescending => compare_path(right.path, left.path)
				LargestFirst =>
					if left.bytes > right.bytes {
						Before
					} else if left.bytes < right.bytes {
						After
					} else {
						compare_path(left.path, right.path)
					}
				}
		}

	compare_path : Str, Str -> [Before, Same, After]
	compare_path = |left, right| compare_bytes(left.to_utf8(), right.to_utf8())

	compare_bytes : List(U8), List(U8) -> [Before, Same, After]
	compare_bytes = |left, right|
		match (left.first(), right.first()) {
			(Ok(a), Ok(b)) =>
				if a < b {
					Before
				} else if a > b {
					After
				} else {
					compare_bytes(left.drop_first(1), right.drop_first(1))
				}
			(Ok(_), Err(_)) => After
			(Err(_), Ok(_)) => Before
			(Err(_), Err(_)) => Same
		}

	summary : List(Entry) -> Summary
	summary = |entries|
		entries.fold(
			{ files: 0, folders: 0, bytes: 0 },
			|total, entry|
				match entry.kind {
					Directory => { ..total, folders: total.folders + 1 }
				File => { ..total, files: total.files + 1, bytes: total.bytes + entry.bytes.to_u128() }
				},
		)

	## Reconcile selection only when a complete scan replaces the dataset.
	## Filtering and sorting must not call this: they do not remove domain entries.
	selection_after_scan : Selection, List(Entry) -> Selection
	selection_after_scan = |selection, entries|
		match selection {
			NoSelection => NoSelection
			Selected(previous) => match entries.find_first(|entry| entry.path == previous.path) {
				Ok(current) => Selected(current)
				Err(_) => NoSelection
			}
		}

	size_text : Entry -> Str
	size_text = |entry|
		match entry.kind {
			Directory => "—"
			File => "${entry.bytes.to_str()} B"
		}
}

## Sorting puts folders first and compares exact paths for a stable name order.
expect {
	entries = [
		{ path: "z.txt", kind: File, bytes: 4 },
		{ path: "src", kind: Directory, bytes: 0 },
		{ path: "a.txt", kind: File, bytes: 8 },
	]
	Explorer.sort(entries, NameAscending).map(|entry| entry.path) == ["src", "a.txt", "z.txt"]
}

## Equal file sizes have a stable name tie break and folders stay first.
expect {
	entries = [
		{ path: "z.txt", kind: File, bytes: 16 },
		{ path: "small.txt", kind: File, bytes: 1 },
		{ path: "src", kind: Directory, bytes: 0 },
		{ path: "a.txt", kind: File, bytes: 16 },
	]
	Explorer.sort(entries, LargestFirst).map(|entry| entry.path) == ["src", "a.txt", "z.txt", "small.txt"]
}

## Search preserves exact international path identity and folds ASCII case.
expect {
	actual = Explorer.filter(Explorer.sample_entries, " DOCS/ ").map(|entry| entry.path)
	actual == ["docs/launch-checklist.md", "docs/research-notes.md", "docs/日本語.md"]
}

## A completed rescan refreshes the selected metadata for a surviving path.
expect {
	before = { path: "notes.md", kind: File, bytes: 12 }
	after = { ..before, bytes: 24 }
	Explorer.selection_after_scan(Selected(before), [after]) == Selected(after)
}

## A completed rescan clears selection when its exact path has disappeared.
expect {
	before = { path: "notes.md", kind: File, bytes: 12 }
	Explorer.selection_after_scan(Selected(before), []) == NoSelection
}

## Totals include empty files but do not add directory metadata to file bytes.
expect {
	entries = [
		{ path: "src", kind: Directory, bytes: 4096 },
		{ path: "empty.txt", kind: File, bytes: 0 },
		{ path: "notes.md", kind: File, bytes: 12 },
	]
	Explorer.summary(entries) == { files: 2, folders: 1, bytes: 12 }
}
