import pf.Engine
import pf.Html
import Time

## The sample keeps a displayed clock, a posted request for an action's
## timestamp, and a generator as separate pieces of ordinary app state.
TimeApp := [Demo].{
	store = Engine.store(
		Demo,
		{
			clock: Engine.cell(0.I64),
			stamps: Engine.cell(Engine.outbox({})),
			action: Engine.cell(not_stamped({})),
			random: Engine.cell(0.U64),
			id: Engine.cell(""),
		}.Engine.Cells,
	)

	cells = store.cells()

	# region clock
	## The first paint uses the mount's sample. Ticks replace it with the
	## callback's wall-clock time rather than counting elapsed intervals.
	start : Engine.Boot -> Engine.Store(_, _)
	start = |boot| TimeApp.store.with_initial(TimeApp.cells.clock, boot.now_ms).with_initial(TimeApp.cells.random, Time.seed_state(boot.seed))

	clock_site : {} -> Engine.Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	clock_site = |_props| Engine.watch(
		Engine.const({}),
		|_| [Engine.interval(30000)],
		Engine.react(
			|_, result| match result {
				Ok(at_ms) => [TimeApp.cells.clock.set(at_ms)]
				_ => []
			},
		),
	)
	# endregion clock

	# region stamp
	## Asking for an action's time posts a request. It does not mistake the
	## displayed clock, which may be an old tick, for a fresh sample.
	stamp : {} -> List(Engine.Write(_))
	stamp = |_props| [TimeApp.cells.action.set(Waiting), TimeApp.cells.stamps.update(|outbox| outbox.post({}))]

	stamp_site : {} -> Engine.Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	stamp_site = |_props| Engine.on_post(
		TimeApp.cells.stamps.signal(),
		|_| [Engine.timer(0)],
		Engine.react_by(
			TimeApp.cells.clock.signal(),
			|clock, _, result| match result {
				Ok(at_ms) => [TimeApp.cells.action.set(Stamped(at_ms))]
				Err(Refused) => [TimeApp.cells.action.set(Stamped(clock))]
				_ => []
			},
		),
	)
	# endregion stamp

	## Both runners mount this same pure program with their supplied facts.
	program : Engine.Program
	program = Engine.program_store({}, TimeApp.start, view)
}

view : Engine.Boot -> Engine.Elem(Engine.StoreRoot(_))
view = |boot| Html.div(
	"grid gap-3",
	[
		Html.p_s(TimeApp.cells.clock.signal().map(|at_ms| at_ms.to_str()), [Engine.test_id("clock")]),
		Html.p_s(TimeApp.cells.clock.signal().map(|at_ms| local_time({ zone: boot.zone, at_ms, language: boot.languages.first() ?? crash "TimeApp.view: boot supplies a language" })), [Engine.test_id("local")]),
		Html.button("Stamp an action", [], Engine.handle(|_| TimeApp.stamp({}))),
		Html.p_s(
			TimeApp.cells.action.signal().map(
				|action| match action {
					NotStamped => "Not stamped"
					Waiting => "Waiting for timer"
					Stamped(at_ms) => at_ms.to_str()
				},
			),
			[Engine.test_id("action")],
		),
		Html.button(
			"Generate id",
			[],
			Engine.handle_by(
				TimeApp.cells.random.signal(),
				|state, _| {
					generated = Time.next(state)
					[TimeApp.cells.random.set(generated.state), TimeApp.cells.id.set(Time.hex(generated.value))]
				},
			),
		),
		Html.p_s(TimeApp.cells.id.signal(), [Engine.test_id("id")]),
		TimeApp.clock_site({}),
		TimeApp.stamp_site({}),
	],
)

# region zone
## A zone is a value with a stated span. A date outside it is an error the
## app handles, rather than using today's offset for a different instant.
local_time : { zone : Engine.Zone, at_ms : I64, language : Str } -> Str
local_time = |{ zone, at_ms, language }| match Engine.zone_offset(zone, at_ms) {
	Err(OutsideZone) => "Outside saved time zone"
	Ok(offset_minutes) => match Time.clock_text({ at_ms, offset_minutes, language }) {
		Ok(clock) => clock
		Err(OutsideCalendar) => "Outside supported calendar"
	}
}
# endregion zone

## A fresh action begins by posting one request, not by copying the clock.
expect {
	initial = TimeApp.start({ now_ms: 123, seed: 7 })
	posted = initial.after(TimeApp.stamp({}))
	{ action: posted.read(TimeApp.cells.action), request: posted.read(TimeApp.cells.stamps).last(), clock: posted.read(TimeApp.cells.clock) } == { action: Waiting, request: Posted({}), clock: 123 }
}

Action : [NotStamped, Waiting, Stamped(I64)]

## Keep the initializer's union closed before store inference; see
## https://github.com/roc-lang/roc/issues/13011.
not_stamped : {} -> Action
not_stamped = |_props| NotStamped
