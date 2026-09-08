import Board

## Versioned board documents contain explicit keys and ordered columns. JSON is
## decoded completely before any live Rows generation is replaced.
Codec := [].{
	Document : { next : U64, planned : List(Board.Task), progress : List(Board.Task), complete : List(Board.Task) }
	WireTask : { key : Str, title : Str, notes : Str, assignee : Str, priority : Str }
	Wire : { version : U64, next : U64, planned : List(WireTask), progress : List(WireTask), complete : List(WireTask) }
	Error := [Invalid(Str)].{
		is_eq : _
	}
	parse : Str -> Try(Wire, [InvalidJson(Str), MissingRequiredField(Str)])
	parse = Json.parser_camel()
	wire_task : Board.Task -> WireTask
	wire_task = |task| { key: task.key, title: task.title, notes: task.notes, assignee: task.assignee, priority: task.priority.to_str() }
	encode : Document -> Str
	encode = |doc| Json.to_str({ version: 1.U64, next: doc.next, planned: doc.planned.map(wire_task), progress: doc.progress.map(wire_task), complete: doc.complete.map(wire_task) })
	task : WireTask -> Try(Board.Task, Error)
	task = |value| {
		priority = match value.priority {
			"Low" => Ok(Low)
			"Normal" => Ok(Normal)
			"High" => Ok(High)
			_ => Err(Invalid("Unknown task priority"))
		}?
		if value.key.is_empty() or value.key.to_utf8().len() > 256 {
			return Err(Invalid("Task keys must contain 1–256 UTF-8 bytes"))
		}
		if value.title.to_utf8().len() > 512 or value.notes.to_utf8().len() > 8192 or value.assignee.to_utf8().len() > 128 {
			return Err(Invalid("Task limits are 512 bytes for titles, 8192 for notes, and 128 for assignees"))
		}
		Ok({ key: value.key, title: value.title, notes: value.notes, assignee: value.assignee, priority })
	}
	tasks : List(WireTask) -> Try(List(Board.Task), Error)
	tasks = |values| {
		var $result = []
		for value in values {
			$result = $result.append(task(value)?)
		}
		Ok($result)
	}
	decode : Str -> Try(Document, Error)
	decode = |text| {
		if text.to_utf8().len() > 1048576 {
			return Err(Invalid("Board documents must be at most one MiB"))
		}
		wire = parse(text) ? |_| Invalid("This file is not a complete board JSON document")
		if wire.version != 1 {
			return Err(Invalid("Unsupported board document version"))
		}
		if wire.planned.len() + wire.progress.len() + wire.complete.len() > 500 {
			return Err(Invalid("A board supports at most 500 tasks"))
		}
		if wire.next == 0 {
			return Err(Invalid("The next task identity must be nonzero"))
		}
		planned = tasks(wire.planned)?
		progress = tasks(wire.progress)?
		complete = tasks(wire.complete)?
		var $keys = Set.empty()
		for value in planned.concat(progress).concat(complete) {
			if $keys.contains(value.key) {
				return Err(Invalid("Task keys must be unique across the board"))
			}
			$keys = $keys.insert(value.key)
			if value.key.starts_with("task-") {
				suffix = value.key.drop_prefix("task-")
				match U64.from_str(suffix) {
					Ok(number) if number >= wire.next => return Err(Invalid("The next task identity must follow all generated task keys"))
					_ => {}
				}
			}
		}
		Ok({ next: wire.next, planned, progress, complete })
	}
}

## JSON round trips multiline text, quotes, backslashes, and Unicode.
expect {
	value = { next: 7.U64, planned: [{ ..Board.new_task(1, "a\"b"), notes: "first\nλ\\second", assignee: "\u(E000)" }], progress: [], complete: [] }
	decoded = Codec.decode(Codec.encode(value))?
	decoded == value
}

## Unknown versions and malformed input never become partial boards.
expect {
	[Codec.decode("{}"), Codec.decode("{\"version\":2,\"next\":1,\"planned\":[],\"progress\":[],\"complete\":[]}")].all(
		|value| match value {
			Err(_) => True
			Ok(_) => False
		},
	)
}

## Duplicate identities across columns are refused before constructing Rows.
expect {
	item = Board.new_task(1, "Same key")
	match Codec.decode(Codec.encode({ next: 2, planned: [item], progress: [item], complete: [] })) {
		Err(_) => True
		Ok(_) => False
	}
}

## Exhausted documents remain readable and saveable without wrapping identity.
expect {
	doc = { next: 18446744073709551615.U64, planned: [], progress: [], complete: [] }
	decoded = Codec.decode(Codec.encode(doc))?
	decoded == doc
}
