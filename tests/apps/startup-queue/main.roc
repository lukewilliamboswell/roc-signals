app [main] { pf: platform "../../../platform/main.roc" }
import pf.Engine
import pf.Html
Store : Engine.Stored([QueueScaling], Bool)

Kind := [Placeholders, Conditionals].{
	is_eq : _
	to_hash : _
}

Route : { waiting : U64, total : U64, kind : Kind }

store = Engine.store(QueueScaling, Engine.cell(False).map(|ready| { ready: ready }))

cells = store.cells()

entries = Engine.entries(
	{},
	[
		{ path: "/queue-small/", route: { waiting: 10.U64, total: 1000.U64, kind: Kind.Placeholders } },
		{ path: "/queue-large/", route: { waiting: 1000.U64, total: 1000.U64, kind: Kind.Placeholders } },
		{ path: "/when-small/", route: { waiting: 0.U64, total: 10.U64, kind: Kind.Conditionals } },
		{ path: "/when-large/", route: { waiting: 0.U64, total: 1000.U64, kind: Kind.Conditionals } },
		{ path: "/queue-short/", route: { waiting: 10.U64, total: 10.U64, kind: Kind.Placeholders } },
	],
)

main : Engine.Program
main = Engine.program_startup_store({}, entries, |_route| store, view)

view : Route -> Engine.Elem(Engine.StoreRoot(_))
view = |cfg| Engine.element(
	"main",
	[],
	[
		Html.button("Toggle", [], Engine.does([cells.ready.update(Bool.not)])),
		match cfg.kind {
			Placeholders => Html.placeholder({ ready: cells.ready.signal() }, Html.Static.text("controlled waiting"), || Engine.text("controlled active"))
			Conditionals => Engine.when(cells.ready.signal(), || Engine.text("controlled waiting"), || Engine.text("controlled waiting"))
		},
	].concat(
		(0.U64..<cfg.total).iter().map(
			|index| match cfg.kind {
				Placeholders => Html.placeholder({ ready: Engine.const(index < cfg.waiting) }, Html.Static.text("waiting"), || Engine.text("active"))
				Conditionals => Engine.when(Engine.const(True), || Engine.text("waiting"), || Engine.text("waiting"))
			},
		).fold([], |out, site| out.append(site)),
	),
)
