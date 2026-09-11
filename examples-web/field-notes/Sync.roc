import Notes
import pf.Action exposing [Action]
import pf.Http
import pf.Ui

Sync := [].{
	Lane : { generation : U64, settled : Notes.TaskView }
	Read : { request : Notes.Request, generation : U64 }
	initial : Sync.Lane
	initial = { generation: 0, settled: TaskIdle }

	## Each occurrence owns its token; a later lane request invalidates its result.
	start : Ui.State(Sync.Lane), Sync.Read -> Action(Sync.Read)
	start = |lane, read| match read.request {
		Idle => Action.none
		Send(token) => {
			generation = read.generation + 1
			Action.then([lane.write(|current| { ..current, generation })], |_| Sync.send!(lane, token, generation))
		}
	}

	send! : Ui.State(Sync.Lane), Str, U64 => Action(Sync.Read)
	send! = |lane, token, generation| {
		request = Http.request_from_method(Http.method_post)
			|> Http.with_uri("/api/notes/sync")
			|> Http.with_body(token.to_utf8())
		settled = match Http.send!(request) {
			Ok(response) => {
				status = Http.response_status(response)
				if status >= 200 and status < 300 and Http.response_body(response) == token.to_utf8() {
					TaskDone(token)
				} else {
					TaskFailed(token)
				}
			}
			Err(_) => TaskFailed(token)
		}
		Action.update([
			lane.write(
				|current| if current.generation == generation {
					{ ..current, settled }
				} else {
					current
				},
			),
		])
	}
}
