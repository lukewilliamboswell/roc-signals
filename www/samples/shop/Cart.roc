import pf.Engine exposing [Cell, Elem, Row, RowRef, State]
import pf.Html

# region type
## A shopping cart: what is in it, and how many of each. The type, its pure
## operations and its view are this one module.
Cart :: { lines : List(Line) }.{

	is_eq : _

	## One thing a shop sells.
	Product : { name : Str, price : U64 }

	## One product in the cart, and how many of it.
	Line : { product : Product, count : U64 }

	empty : Cart
	empty = { lines: [] }

	## The cart with one more of `product`.
	add : Cart, Product -> Cart
	add = |cart, product|
		if cart.lines.any(|line| line.product.name == product.name) {
			{ lines: cart.lines.map(|line| if (line.product.name == product.name) { ..line, count: line.count + 1 } else line) }
		} else {
			{ lines: cart.lines.append({ product, count: 1 }) }
		}

	## The cart without the product called `name`.
	remove : Cart, Str -> Cart
	remove = |cart, name| { lines: cart.lines.drop_if(|line| line.product.name == name) }

	## How many of the product called `name` the cart holds.
	quantity : Cart, Str -> U64
	quantity = |cart, name| cart.lines.keep_if(|line| line.product.name == name).fold(0, |sum, line| sum + line.count)

	## How many things the cart holds.
	size : Cart -> U64
	size = |cart| cart.lines.fold(0, |sum, line| sum + line.count)

	## What the cart costs.
	total : Cart -> U64
	total = |cart| cart.lines.fold(0, |sum, line| sum + line.count * line.product.price)
	# endregion type

	# region cells
	## What the view is drawn over, in a store whose storage is `st`: the
	## cart, and a note for whoever delivers it.
	Props(st) : { cart : Cell(st, Cart), note : Cell(st, Str) }

	## What an app's store holds for a cart: its cells, and
	## the write that starts every one of them again.
	Basket(st) : { cells : Props(st), reset : Engine.Write(st) }

	## The cart's cells, for an app to nest in its store. `reset` is
	## generated from this description, so a cell added here later is
	## started again with the rest.
	cells : {} -> Engine.Cells(whole, _, Basket(whole))
	cells = |{}| {
		cart: Engine.cell(Cart.empty),
		note: Engine.cell(""),
	}.Engine.Cells.with_reset(|described, reset| { cells: described, reset })
	# endregion cells

	# region view
	## Whether the cart's panel is open.
	Panel : [Open, Closed]

	## The cart, drawn over its cells. Whether the panel is open is the
	## view's own state: no one else reads it, so it is not in the store.
	view : Props(st) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	view = |props|
		Engine.state(
			Closed,
			|panel| Html.section(
				"Cart",
				"cart",
				[
					Html.button_s(props.cart.signal().map(|cart| "Cart (${cart.size().to_str()})"), [], panel.update(toggled)),
					Engine.when(panel.signal().map(|shown| shown == Open), || Cart.contents(props, panel), || Engine.text("")),
				],
			),
		)
	# endregion view

	# region contents
	## The open panel: the cart's lines, its total, the note, and a button
	## that empties the cart.
	contents : Props(st), State(ctx, Panel) -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	contents = |props, panel| {
		held = props.cart.signal()
		# region also
		# One click, two writes: the panel closes, which is the view's own
		# state, and the cart is emptied, which is the store's.
		emptied = panel.update(|_| Closed).also(Engine.does([props.cart.set(Cart.empty)]))
		# endregion also
		Html.div(
			"lines",
			[
				Html.ul([], [Engine.each(held.map(|cart| cart.lines), |line| line.product.name, |row| Cart.line_row(props, row))]),
				Html.p_s(held.map(|cart| "Total ${cart.total().to_str()}"), [Engine.test_id("total")]),
				note_box("Note for the courier", props.note.state()),
				Html.button("Empty cart", [], emptied),
			],
		)
	}

	## One line of the cart, in a row of its list. The row writes the cart's
	## cell with no `lift`.
	line_row : Props(st), RowRef(ctx, Line) -> Elem(Row(ctx, Line))
		where [ctx.store : () -> Engine.Reach(ctx, st)]
	line_row = |props, row| {
		name = row.key()
		Html.li(
			[],
			[
				Engine.text_s(row.field(|held| "${held.count.to_str()} × ${held.product.name}")),
				Html.button_s(name.map(|product| "Remove ${product}"), [], Engine.handle_by(name, |product, _| [props.cart.update(|cart| cart.remove(product))])),
			],
		)
	}
	# endregion contents
}

toggled : Cart.Panel -> Cart.Panel
toggled = |shown|
	match shown {
		Open => Closed
		Closed => Open
	}

# region note-box
## A text box over a `State`. It cannot tell whose state that is: here the
## cart hands it a cell of the app's store, as `props.note.state()`.
note_box : Str, State(ctx, Str) -> Elem(ctx)
note_box = |label, text| Html.text_input(Engine.const(label), "text", text.signal(), [], text.set_value(|_, typed| typed))
# endregion note-box

# region expects
## Adding a product twice makes one line of two, and the total follows.
expect {
	tea = { name: "Tea", price: 4 }
	cart = Cart.empty.add(tea).add({ name: "Bread", price: 3 }).add(tea)

	actual =
		\\size: ${cart.size().to_str()}
		\\tea: ${cart.quantity("Tea").to_str()}
		\\total: ${cart.total().to_str()}
		\\without tea: ${cart.remove("Tea").total().to_str()}
	expected =
		\\size: 3
		\\tea: 2
		\\total: 11
		\\without tea: 3
	actual == expected
}
# endregion expects
