import pf.Engine
import pf.Html
import pf.Svg

## Real static, reactive and keyed uses of both markup formats. Handlers stay
## on constructors, while the literal bodies contain only structure and data.
MarkupApp := [].{
	Model : { count : U64, text : Str, rows : List(Str), shown : Bool }
	Ctx : Engine.In(Engine.Root, Model)
	RowCtx : Engine.Row(Ctx, Str)

	initial : Model
	initial = { count: 0, text: "first", rows: ["one", "two"], shown: True }

	program : Engine.Program
	program = Engine.program(|| Engine.state(MarkupApp.initial, MarkupApp.view))

	view : Engine.State(Ctx, Model) -> Engine.Elem(Ctx)
	view = |state| {
		value = state.signal()
		text = value.map(|model| model.text)
		count = value.map(|model| model.count).to_text_signal()
		static : Html.Markup(Ctx)
		static = "<article class='static-card' data-testid='static-card' data-n='app-node' data-h='app-hole'><h2>Literal card</h2><p>fixed &amp; escaped</p><!--roc:node=9--></article>"
		reactive : Html.Markup(Ctx)
		reactive =
			\\<section class="card" data-testid="reactive-card">
			\\  <p data-testid="literal-text">${text}</p>
			\\  <!--roc:row=123-->
			\\  <span data-testid="${Engine.const("bound-id")}">${text}</span>
			\\  <p data-testid="literal-count">${count}</p>
			\\</section>
		booleans : Html.Markup(Ctx)
		booleans = "<fieldset><input aria-label='Literal disabled' disabled><p hidden='until-found' data-testid='literal-hidden'>findable</p></fieldset>"
		drawing : Svg.Markup(Ctx)
		drawing =
			\\<svg viewBox="0 0 100 100" aria-label="Literal drawing" width="100" height="100">
			\\  <defs><linearGradient id="literal-gradient"><stop offset="0%" stop-color="red"/><stop offset="100%" stop-color="blue"/></linearGradient></defs>
			\\  <!--roc:node=88-->
			\\  <path data-testid="literal-path" d="M0 0 L10 10" pathLength="10" fill="none"/>
			\\</svg>
		inert : Html.Markup(Ctx)
		inert = "<template data-testid='literal-template'><span data-testid='inert-descendant'>inert data</span><!--template comment--></template>"
		xml_inert : Svg.Markup(Ctx)
		xml_inert = "<svg><foreignObject><h:template xmlns:h='http://www.w3.org/1999/xhtml' data-testid='xml-template'><h:span data-testid='xml-inert-descendant'>xml data</h:span><!--xml template comment--></h:template></foreignObject></svg>"
		formula : Html.Markup(Ctx)
		formula = "<math data-testid='literal-math'><mrow><mi>x</mi><mo>+</mo><mn>${count}</mn></mrow></math>"
		Engine.element(
			"main",
			[],
			[
				Html.button("Step", [], state.update(|model| { ..model, count: model.count + 1, text: "second" })),
				Html.button("Same", [], state.update(|model| model)),
				Html.button("Swap rows", [], state.update(|model| { ..model, rows: model.rows.fold([], |reversed, row| [row].concat(reversed)) })),
				Html.button("Toggle region", [], state.update(|model| { ..model, shown: !model.shown })),
				Html.button("Reset", [], state.update(|_| MarkupApp.initial)),
				static.to_elem(),
				reactive.to_elem(),
				booleans.to_elem(),
				drawing.to_elem(),
				inert.to_elem(),
				xml_inert.to_elem(),
				formula.to_elem(),
				Engine.element("ul", [Engine.test_id("html-rows")], [Engine.each(value.map(|model| model.rows), |row| row, MarkupApp.html_row)]),
				Engine.element("svg", [Engine.test_id("svg-rows"), Engine.attr("viewBox", "0 0 100 100")], [Engine.each(value.map(|model| model.rows), |row| row, |row| MarkupApp.svg_row(row, count.lift_row()))]),
				Engine.when(
					value.map(|model| model.shown),
					|| {
						region : Html.Markup(Ctx)
						region = "<section data-testid='literal-region'><p>${text}</p><!--region comment--></section>"
						region.to_elem()
					},
					|| Engine.text(""),
				),
			],
		)
	}

	html_row : Engine.RowRef(Ctx, Str) -> Engine.Elem(RowCtx)
	html_row = |row| {
		markup : Html.Markup(RowCtx)
		markup = "<li data-testid='${row.key().map(|key| "html-${key}")}'>${row.item()}<!--row comment--></li>"
		markup.to_elem()
	}

	svg_row : Engine.RowRef(Ctx, Str), Engine.Signal(RowCtx, Str) -> Engine.Elem(RowCtx)
	svg_row = |row, count| {
		markup : Svg.Markup(RowCtx)
		markup =
			\\<g data-testid="${row.key().map(|key| "svg-${key}")}">
			\\  <!--roc:row=456-->
			\\  <defs><linearGradient id="${row.key().map(|key| "gradient-${key}")}"><stop offset="0%" stop-color="red"/></linearGradient></defs>
			\\  <path d="M0 0 L10 10" pathLength="${count}"/>
			\\  <foreignObject><h:div xmlns:h="http://www.w3.org/1999/xhtml" data-testid="${row.key().map(|key| "foreign-${key}")}">${row.item()}</h:div></foreignObject>
			\\</g>
		markup.to_elem()
	}
}
