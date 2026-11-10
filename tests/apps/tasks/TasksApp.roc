import pf.Engine exposing [Elem, File, In, Root, State]
import pf.Html
import pf.Worker

## Tasks test app: worker tasks read the files they are sent through
## effects and answer with files they built.
TasksApp := [].{
	S : { files : List(File), out : List(File), ask : Ask }

	Ask : [Nothing, Upper(File)]

	## Upper-case a file in chunks into a new file.
	upper : Worker.Task({ source : File, chunk : U64 }, Try(File, Engine.FileError))
	upper = Worker.fallible_task({ name: "test.roc-signals/tasks/upper", run!: TasksApp.upper! })

	upper! : { source : File, chunk : U64 } => Try(File, Engine.FileError)
	upper! = |{ source, chunk }| {
		out = File.build!({ name: "${source.name()}.upper", mime: Mime("text/plain") })
		var $at = 0.U64
		while $at < source.size() {
			len = if (source.size() - $at < chunk) source.size() - $at else chunk
			bytes = source.read!({ start: $at, len })?
			out.append!(bytes.map(|b| if (b >= 'a' and b <= 'z') b - 32 else b))?
			$at = $at + len
		}
		Ok(out.finish!())
	}

	Ctx : In(Root, S)

	received : S, Engine.Received -> S
	received = |s, { files, refused: _ }| { ..s, files: s.files.concat(files) }

	asked : Ask -> [Run({ source : File, chunk : U64 }), Skip]
	asked = |a| match a {
		Upper(f) => Run({ source: f, chunk: 4 })
		Nothing => Skip
	}

	view : State(Ctx, S) -> Elem(Ctx)
	view = |st| {
		v = st.val()
		Html.div(
			"tasks",
			[
				Html.file_input(Engine.const("Upload"), { accept: "", multiple: Bool.True }, st.on_files(TasksApp.received)),
				Html.button(
					"Upper",
					[],
					st.update(
						|s| match s.files {
							[first, ..] => { ..s, ask: Upper(first) }
							[] => s
						},
					),
				),
				Worker.derive_when(
					TasksApp.upper,
					v.map(|s| TasksApp.asked(s.ask)),
					|r| Html.p_v(
						r.map(
							|{ answer, running }| match answer {
								Nothing => if (running) "running" else "idle"
								Done(Ok(f)) => "built ${f.name()}:${f.size().to_str()}"
								Done(Err(e)) => "error ${Str.inspect(e)}"
								Failed(e) => "failed ${Str.inspect(e)}"
							},
						),
						[Engine.test_id("upper")],
					),
				),
			],
		)
	}

	program : Engine.Program
	program = Engine.program(|| Engine.state({ files: [], out: [], ask: Nothing }, TasksApp.view)).with_workers([TasksApp.upper.registration()])
}
