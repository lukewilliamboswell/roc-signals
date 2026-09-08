import pf.Rows

## Deterministic demonstration events, deliberately unrelated to host telemetry.
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
	History : { rows : Rows.Rows(Entry), next_id : U64 }

	capacity : U64
	capacity = 1000

	key : Entry -> Str
	key = |entry| entry.id.to_str()

	empty : History
	empty = { rows: Rows.from_list([], key) ?? crash "Empty history has duplicate keys", next_id: 1 }

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

	append : History -> History
	append = |history| {
		if history.next_id == 18446744073709551615 {
			crash "Activity sequence exhausted"
		}
		changes = if history.rows.len() == capacity {
			[RemoveRange({ at: 0, count: 1 }), Append([event(history.next_id)])]
		} else {
			[Append([event(history.next_id)])]
		}
		{ rows: Rows.apply(history.rows, changes) ?? crash "Invalid activity history edit", next_id: history.next_id + 1 }
	}

	clear : History -> History
	clear = |history| { rows: Rows.replace_all(history.rows, []) ?? crash "Invalid history clear", next_id: history.next_id }

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
