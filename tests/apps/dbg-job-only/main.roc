app [main] { pf: platform "../../../platform/main.roc" }
import pf.Engine
import pf.Html
import pf.Worker

## This fixture has no shared store and no page debug observations.
Store : {}

## The job is the only source of debug text in this compiled module.
job : Worker.Task(I64, Str, Worker.Never)
job = Worker.task({
	name: "dbg/only-job",
	run!: |input| {
		dbg { at: "only-job", input }
		Ok("job:${input.to_str()}")
	},
})

## Render ordinary task answers without observing the page's evaluations.
view : Engine.State(Engine.In(Engine.Root, I64), I64) -> Engine.Elem(Engine.In(Engine.Root, I64))
view = |count| Html.div(
	"job-only",
	[
		Html.button("Increment", [], count.update(|previous| previous + 1)),
		Html.button("Reset", [], count.update(|_previous| 0)),
		Worker.resource(
			job,
			count.signal(),
			|remote| Html.p_s(
				remote.map(
					|value| match value.answer {
						Answered(text) => text
						_ => "waiting"
					},
				),
				[Engine.test_id("answer")],
			),
		),
	],
)

## A normal page with one registered task is shared by both spec runners.
main : Engine.Program
main = Engine.program(|| Engine.state(0.I64, view)).with_workers([job.registration()])

## The default page remains checked at compile time without running its job.
mounted : U64
mounted = Engine.mounts(main)
