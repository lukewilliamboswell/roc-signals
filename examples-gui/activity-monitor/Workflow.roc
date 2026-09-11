import pf.Action exposing [Action]
import pf.Elem exposing [Elem]
import pf.Files
import pf.Signal
import pf.Ui
import LogReader
import Session

## Every native step is the effect of the handler that asked for it: opening a
## log runs the chooser, which blocks until the user answers, and then drains
## the chosen file; resuming, retrying, and polling drain from the accepted
## cursor. A drain reads consecutive chunks while the file has more, up to
## `drain_chunks` per effect, and commits them together; a caught-up file is
## polled by a scoped timer that exists only while the session waits on it.
Workflow := [].{
	drain_chunks = 64

	## Polls the followed file every 500 ms while the session is waiting for
	## more of it; each tick moves the session into `Reading` and drains from
	## the accepted cursor.
	poll : Ui.State(Session.Accepted) -> Elem
	poll = |model| Ui.when(
		model.read(|value| value.session.phase == Session.Phase.Waiting),
		|| Action.every(500, model.read(|value| value.session), |_| Action.then([model.write(|value| { ..value, session: Session.read_next(value.session) })], |current| advance!(model, current))),
		|| Elem.text(""),
	)

	## Opens the chooser and drains the chosen log from its start.
	open! : Ui.State(Session.Accepted) => Action(a)
	open! = |model| match Files.choose_file!() {
		Err(error) => failed(model, error)
		Ok(Files.Choice.Canceled) => Action.update([model.write(|value| { ..value, session: Session.chosen(value.session, Files.Choice.Canceled) })])
		Ok(Files.Choice.Chosen(path)) => Action.then(
			[model.write(|value| { ..value, session: Session.chosen(value.session, Files.Choice.Chosen(path)) })],
			|_| drain!(model, { path, position: LogReader.Position.Start }),
		)
	}

	## Drains the read the session's phase asks for, after a handler moved it
	## into `Reading`.
	advance! : Ui.State(Session.Accepted), Session.State => Action(a)
	advance! = |model, state| match state.phase {
		Session.Phase.Reading(request) => drain!(model, request)
		_ => Action.none
	}

	drain! : Ui.State(Session.Accepted), Session.Request => Action(a)
	drain! = |model, request| match read_chunks!(request, []) {
		Ok(chunks) => Action.update([model.write(|value| Session.accept_all(value.session, value.history, chunks))])
		Err(error) => failed(model, error)
	}

	## A failure after some chunks were read keeps them; the next poll meets
	## the failure again from the accepted cursor.
	read_chunks! : Session.Request, List(LogReader.Chunk) => Try(List(LogReader.Chunk), Files.Error)
	read_chunks! = |request, chunks| match LogReader.read!(request) {
		Err(error) => if chunks.is_empty() {
			Err(error)
		} else {
			Ok(chunks)
		}
		Ok(chunk) => {
			collected = chunks.append(chunk)
			if chunk.state == LogReader.State.More and collected.len() < drain_chunks {
				read_chunks!({ path: chunk.path, position: LogReader.Position.After(chunk.cursor) }, collected)
			} else {
				Ok(collected)
			}
		}
	}

	failed : Ui.State(Session.Accepted), Files.Error -> Action(a)
	failed = |model, error| Action.update([model.write(|value| { ..value, session: Session.failed(value.session, Files.error_text(error)) })])
}
