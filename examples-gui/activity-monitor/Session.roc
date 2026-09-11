import pf.Files
import LogReader
import Feed
import LineStream

## Only accepted reads advance the file cursor. Choosing, errors, and paused
## reads preserve the last accepted history; a new source commits on first data.
Session := [].{
	Source := [Replay, Log({ path : Str, position : LogReader.Position })].{
		is_eq : _
	}
	Request : { path : Str, position : LogReader.Position }
	Phase := [Idle, Choosing, Reading(Request), Waiting, Paused].{
		is_eq : _
	}
	State : { source : Source, phase : Phase, lines : LineStream.State, notice : Str, retry : [None, Some(Request)] }
	Accepted : { session : State, history : Feed.History }

	initial : State
	initial = { source: Replay, phase: Idle, lines: LineStream.empty, retry: None, notice: "Replay is simulated. Open a UTF-8 log to follow a real file." }

	choose : State -> State
	choose = |state| { ..state, phase: Choosing, retry: None, notice: "Choose a UTF-8 plain-text log. Previous history remains available." }

	chosen : State, Files.Choice -> State
	chosen = |state, choice| match (state.phase, choice) {
		(Choosing, Files.Choice.Chosen(path)) => { ..state, phase: Reading({ path, position: LogReader.Position.Start }), notice: "Opening ${path}…" }
		(Choosing, Files.Choice.Canceled) => pause(state)
		_ => crash "A log choice arrived outside its operation"
	}

	read_next : State -> State
	read_next = |state| match state.source {
		Replay => state
		Log(request) => { ..state, phase: Reading(request), notice: "Reading ${request.path}…" }
	}

	pause : State -> State
	pause = |state| { ..state, phase: Paused, retry: None, notice: "Paused. Retained history and the accepted file position are preserved." }

	failed : State, Str -> State
	failed = |state, detail| {
		retry = match state.phase {
			Reading(request) => Some(request)
			_ => state.retry
		}
		{ ..state, phase: Paused, notice: detail, retry }
	}

	retry_read : State -> State
	retry_read = |state| match state.retry {
		Some(request) => { ..state, phase: Reading(request), retry: None, notice: "Retrying ${request.path}…" }
		None => state
	}

	accept : State, Feed.History, LogReader.Chunk -> Accepted
	accept = |state, history, chunk| {
		request = match state.phase {
			Reading(active) if active.path == chunk.path => active
			_ => crash "A log read arrived outside its matching operation"
		}
		reset = request.position == LogReader.Position.Start or chunk.change == LogReader.Change.Rotated or chunk.change == LogReader.Change.Truncated
		lines = if reset {
			LineStream.empty
		} else {
			state.lines
		}
		match LineStream.accept(lines, chunk.text) {
			Err(LineStream.Error.LineTooLong) => {
				session: failed(state, "Paused: a log line exceeds 16 KiB. The read was refused; history and the last accepted position are unchanged."),
				history,
			}
			Ok(assembled) => {
				position = LogReader.Position.After(chunk.cursor)
				phase = if chunk.state == LogReader.State.More {
					Reading({ path: chunk.path, position })
				} else {
					Waiting
				}
				notice = match chunk.change {
					LogReader.Change.Rotated => "File replaced: retained history restarted from the new file."
					LogReader.Change.Truncated => "File truncated: retained history restarted from the beginning."
					_ => match chunk.state {
						LogReader.State.More => "Reading existing log records…"
						LogReader.State.PartialUtf8 => "Following file; waiting for a complete UTF-8 character."
						LogReader.State.AtEnd => if assembled.state.partial.is_empty() {
							"Following file; caught up."
						} else {
							"Following file; waiting for the final line's newline."
						}
					}
				}
				{
					session: { source: Log({ path: chunk.path, position }), phase, lines: assembled.state, notice, retry: None },
					history: Feed.append_lines(
						if reset {
							Feed.clear(history)
						} else {
							history
						},
						assembled.lines,
					),
				}
			}
		}
	}
}

## A refused long line never advances the accepted cursor or destroys history.
expect {
	before = { ..Session.initial, phase: Session.Phase.Reading({ path: "/log", position: LogReader.Position.Start }) }
	history = Feed.append(Feed.empty)
	result = Session.accept(
		before,
		history,
		{
			path: "/log",
			text: Str.join_with(List.repeat("x", 16385), ""),
			cursor: { device: 1, inode: 2, offset: 16385 },
			change: LogReader.Change.Initial,
			state: LogReader.State.AtEnd,
		},
	)
	result.session.source == before.source and result.session.phase == Session.Phase.Paused and result.history.next_id == history.next_id
}

## A replacement file cannot inherit an unfinished line from the retired file.
expect {
	first = Session.accept(
		{ ..Session.initial, phase: Session.Phase.Reading({ path: "/log", position: LogReader.Position.Start }) },
		Feed.empty,
		{
			path: "/log",
			text: "old\npartial",
			cursor: { device: 1, inode: 2, offset: 11 },
			change: LogReader.Change.Initial,
			state: LogReader.State.AtEnd,
		},
	)
	rotated = Session.accept(
		Session.read_next(first.session),
		first.history,
		{
			path: "/log",
			text: "new\n",
			cursor: { device: 1, inode: 3, offset: 4 },
			change: LogReader.Change.Rotated,
			state: LogReader.State.AtEnd,
		},
	)
	rotated.history.rows.len() == 1 and rotated.history.rows.get(0)?.message == "new" and rotated.history.rows.get(0)?.id == 2 and rotated.session.lines.partial == ""
}

## Read failure exposes an exact retry without moving the accepted source.
expect {
	request = { path: "/log", position: LogReader.Position.Start }
	state = { ..Session.initial, phase: Session.Phase.Reading(request) }
	failed = Session.failed(state, "Permission denied")
	Session.retry_read(failed).phase == Session.Phase.Reading(request) and failed.source == Session.Source.Replay
}
