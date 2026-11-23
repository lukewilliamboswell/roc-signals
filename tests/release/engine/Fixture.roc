import engine.Engine
import engine.EngineHost
import engine.Port
import engine.Worker

Fixture := [].{
	program : Engine.Program({})
	program = Engine.program(
		|| Engine.state(
			"",
			|state| {
				Engine.element(
					"div",
					[
						Engine.on("input", state.set_value(|_, value| value)),
						Engine.on_files(Drop, state.set_value(|_, files| files.files.len().to_str())),
					],
					[Engine.text_s(state.signal())],
				)
			},
		),
	).with_ports(Port.registrations({ notice: notice })).with_workers([prep.registration([task.registration()])])

	notice : Port.Command(Str)
	notice = Port.command({ name: "notice" })

	Problem : [Failed]

	prep : Worker.Preparation(U8, U8, Problem)
	prep = Worker.preparation({ name: "prep", prepare!: |value| Ok(value + 1) })

	task : Worker.PreparedTask(U8, U8, U8, U8, Problem)
	task = prep.task({ name: "task", run!: |state, value| Ok(state + value) })

	effects : EngineHost.JobEffects
	effects = {
		read!: |_, _, _| crash "unexpected read",
		size!: |_| crash "unexpected size",
		mint!: || crash "unexpected mint",
		open!: |_, _, _, _, _, _| crash "unexpected open",
		append!: |_, _| crash "unexpected append",
		append_file!: |_, _, _, _| crash "unexpected append_file",
		finish!: |_, _| crash "unexpected finish",
	}

	worker_check! : () => {}
	worker_check! = || {
		held = EngineHost.work_prepare!(Fixture.program, effects, [4, 0, 0, 0, 112, 114, 101, 112, 2], [])
		if EngineHost.work_ask!(held, [4, 0, 0, 0, 116, 97, 115, 107, 3], []) == [0, 0, 0, 0, 6, 0] {
			{}
		} else {
			crash "wrong prepared job answer"
		}
	}
}
