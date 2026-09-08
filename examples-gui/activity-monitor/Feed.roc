import pf.Rows

## Bounded event history shared by explicit replay and plain-text log sources.
Feed :: [].{
	Severity := [Info, Warning, Error].{
		is_eq : _

		to_str : Severity -> Str
		to_str = |severity| match severity {
			Info => "INFO"
			Warning => "WARN"
			Error => "ERROR"
		}
	}

	Entry : { id : U64, severity : Severity, component : Str, message : Str }
	History : { rows : Rows.Rows(Entry), next_id : U64, bytes : U64, discarded : U64 }

	capacity : U64
	capacity = 1000

	byte_capacity : U64
	byte_capacity = 4194304

	key : Entry -> Str
	key = |entry| entry.id.to_str()

	empty : History
	empty = { rows: Rows.from_list([], key) ?? crash "Empty history has duplicate keys", next_id: 1, bytes: 0, discarded: 0 }

	event : U64 -> Entry
	event = |id| {
		detail = match id.rem_by(6) {
			0 => { severity: Error, component: "Indexer", message: "Sample document could not be decoded" }
			1 => { severity: Info, component: "Workspace", message: "Workspace snapshot loaded" }
			2 => { severity: Info, component: "Indexer", message: "Search index updated" }
			3 => { severity: Warning, component: "Sync", message: "Simulated connection delay; retry scheduled" }
			4 => { severity: Info, component: "Sync", message: "Pending changes synchronized" }
			_ => { severity: Info, component: "Renderer", message: "Preview refreshed" }
		}
		{ id, severity: detail.severity, component: detail.component, message: detail.message }
	}

	entry_bytes : Entry -> U64
	entry_bytes = |entry| entry.component.to_utf8().len() + entry.message.to_utf8().len()

	append : History -> History
	append = |history| append_entries(history, [event(history.next_id)], 1)

	## Source lines already passed LineStream's size limit. If a read contains
	## more than the retention window, assign every line a sequence number but
	## materialize only the newest thousand rows. Eviction stays explicit.
	append_lines : History, List(Str) -> History
	append_lines = |history, lines| {
		count = lines.len()
		if count >= 18446744073709551615 - history.next_id {
			crash "Activity sequence exhausted"
		}
		skipped = if count > capacity {
			count - capacity
		} else {
			0
		}
		zero : U64
		zero = 0
		var $index = zero
		var $entries = []
		for line in lines.drop_first(skipped) {
			id = history.next_id + skipped + $index
			$index = $index + 1
			$entries = $entries.append({ id, severity: Info, component: "Log", message: line })
		}
		append_entries(history, $entries, count)
	}

	append_entries : History, List(Entry), U64 -> History
	append_entries = |history, entries, consumed| {
		if consumed >= 18446744073709551615 - history.next_id {
			crash "Activity sequence exhausted"
		}
		zero : U64
		zero = 0
		added_bytes = entries.fold(zero, |bytes, entry| bytes + entry_bytes(entry))
		if added_bytes > byte_capacity {
			crash "Activity batch exceeds retention capacity"
		}
		var $remove = zero
		var $bytes = history.bytes + added_bytes
		while history.rows.len() - $remove + entries.len() > capacity or $bytes > byte_capacity {
			entry = history.rows.get($remove) ?? crash "Invalid activity eviction index"
			$bytes = $bytes - entry_bytes(entry)
			$remove = $remove + 1
		}
		changes = if $remove > 0 {
			[RemoveRange({ at: 0, count: $remove }), Append(entries)]
		} else {
			[Append(entries)]
		}
		{
			rows: Rows.apply(history.rows, changes) ?? crash "Invalid activity history edit",
			next_id: history.next_id + consumed,
			bytes: $bytes,
			discarded: history.discarded + $remove + consumed - entries.len(),
		}
	}

	clear : History -> History
	clear = |history| {
		rows: Rows.replace_all(history.rows, []) ?? crash "Invalid history clear",
		next_id: history.next_id,
		bytes: 0,
		discarded: 0,
	}

	visible : History, Str, Bool -> Rows.Rows(Entry)
	visible = |history, query, errors_only| {
		if query.is_empty() and !errors_only {
			history.rows
		} else {
			items = history.rows.to_list().keep_if(
				|entry|
					(!errors_only or entry.severity == Error) and
						(entry.component.contains(query) or entry.message.contains(query) or entry.severity.to_str().contains(query)),
			)
			Rows.replace_all(history.rows, items) ?? crash "Filtered activity has duplicate keys"
		}
	}
}

## Clearing history never recycles event identities.
expect {
	first = Feed.append(Feed.empty)
	second = Feed.append(Feed.clear(first))
	second.rows.get(0)?.id == 2
}

## The replay retains exactly the newest thousand events.
expect {
	var $history = Feed.empty
	for _ in List.repeat({}, 1005) {
		$history = Feed.append($history)
	}
	$history.rows.len() == Feed.capacity and $history.rows.get(0)?.id == 6 and $history.rows.get(999)?.id == 1005
}

## Error filtering matches the explicit severity and preserves stable identities.
expect {
	var $history = Feed.empty
	for _ in List.repeat({}, 12) {
		$history = Feed.append($history)
	}
	Feed.visible($history, "Indexer", True).to_list().map(Feed.key) == ["6", "12"]
}

## A large source read numbers every record but only materializes retained rows.
expect {
	history = Feed.append_lines(Feed.empty, List.repeat("line", 1200))
	history.rows.len() == 1000 and history.rows.get(0)?.id == 201 and history.next_id == 1201 and history.discarded == 200
}

## Payload retention is bounded independently of row count.
expect {
	line = Str.join_with(List.repeat("x", 16384), "")
	var $history = Feed.empty
	for _ in List.repeat({}, 300) {
		$history = Feed.append_lines($history, [line])
	}
	$history.bytes <= Feed.byte_capacity and $history.rows.len() < Feed.capacity and $history.discarded > 0
}
