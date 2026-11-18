app [main] { pf: platform "../../../platform/main.roc" }
import pf.Engine
import pf.Html

store = Engine.store(PreparedPage, Engine.cell(0.I64).map(|count| { count: count }))

cells = store.cells()

Store : Engine.Stored([PreparedPage], I64)

# region description
## A description can be prepared before any instance has a value to read.
prepared_page : Engine.Elem(Engine.StoreRoot(_))
prepared_page = Html.div(
	"",
	[
		Html.p_s(cells.count.signal().to_text_signal(), []),
		Html.button("Add one", [], Engine.does([cells.count.update(|count| count + 1)])),
	],
)

main : Engine.Program
main = Engine.program_store(
	{},
	|boot| store.with_initial(cells.count, boot.now_ms),
	|_boot| prepared_page,
)

# endregion description

mounted : U64
mounted = Engine.mounts(main)
