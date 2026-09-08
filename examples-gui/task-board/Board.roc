## Pure task-board vocabulary. Task keys identify records independently of their
## editable titles, position, and current column.
Board :: [].{
	Column := [Planned, InProgress, Complete].{
		is_eq : _

		to_str : Column -> Str
		to_str = |column|
			match column {
				Planned => "Planned"
				InProgress => "In progress"
				Complete => "Complete"
			}
	}

	Priority := [Low, Normal, High].{
		is_eq : _

		to_str : Priority -> Str
		to_str = |priority|
			match priority {
				Low => "Low"
				Normal => "Normal"
				High => "High"
			}
	}

	Task : {
		key : Str,
		title : Str,
		notes : Str,
		assignee : Str,
		priority : Priority,
	}

	columns : List(Column)
	columns = [Planned, InProgress, Complete]

	priorities : List(Priority)
	priorities = [Low, Normal, High]

	seed : Column -> List(Task)
	seed = |column|
		match column {
			Planned => [
				{ key: "task-1", title: "Sketch the welcome screen", notes: "Show a useful first project before asking people to configure anything.", assignee: "Maya", priority: High },
				{ key: "task-2", title: "Write the empty-state copy", notes: "Explain the next action in a short sentence. Include the no-search-results state.", assignee: "Jon", priority: Normal },
				{ key: "task-3", title: "Review keyboard navigation", notes: "Walk through creating and moving a task using the keyboard alone.", assignee: "Sam", priority: High },
			]
			InProgress => [
				{ key: "task-4", title: "Polish the project sidebar", notes: "Make the selected project obvious and keep long names readable.", assignee: "Maya", priority: Normal },
				{ key: "task-5", title: "Test the import flow", notes: "Cover cancel, an empty folder, and a permission failure.", assignee: "Sam", priority: High },
			]
			Complete => [
				{ key: "task-6", title: "Agree on the launch checklist", notes: "The team agreed on a small first release and a separate follow-up list.", assignee: "Jon", priority: Low },
			]
		}

	new_task : U64, Str -> Task
	new_task = |number, title| {
		key: "task-${number.to_str()}",
		title: title.trim(),
		notes: "",
		assignee: "Unassigned",
		priority: Normal,
	}

	## Search matches titles, notes, and assignees. ASCII case folding preserves
	## every non-ASCII UTF-8 byte, so international names remain valid text.
	matches : Task, Str -> Bool
	matches = |task, query| {
		needle = search_text(query.trim())
		search_text(task.title).contains(needle) or search_text(task.notes).contains(needle) or search_text(task.assignee).contains(needle)
	}

	search_text : Str -> Str
	search_text = |value|
		Str.from_utf8(
			value.to_utf8().map(
				|byte| if byte >= 65 and byte <= 90 {
					byte + 32
				} else {
					byte
				},
			),
		) ?? crash "ASCII case folding must preserve UTF-8"
}

## A task's identity is independent of its user-editable title.
expect {
	task = Board.new_task(7, "  Review the launch  ")
	{ key: task.key, title: task.title } == { key: "task-7", title: "Review the launch" }
}

## Search includes notes and assignees without requiring matching ASCII case.
expect {
	task = Board.seed(InProgress).first()?
	actual = [Board.matches(task, "SIDEBAR"), Board.matches(task, "maya"), Board.matches(task, "long names"), Board.matches(task, "billing")]
	actual == [True, True, True, False]
}

## Case folding retains international names and an empty search matches a task.
expect {
	task = { ..Board.new_task(7, "Café launch"), assignee: "Zoë" }
	[Board.matches(task, "café"), Board.matches(task, "Zoë"), Board.matches(task, "  ")] == [True, True, True]
}
