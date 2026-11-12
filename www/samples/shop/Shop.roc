import pf.Engine exposing [Elem, Row, RowRef]
import pf.Html
import Cart

## A small shop: products to add to a cart, and an order sent to a server.
## The cart, the notice and the count of orders are state that several
## parts of the page care about, so they are cells of the app's store.
Shop := [CornerShop].{

	# region store
	## The shop's store: its name, and its cells with their starting
	## values. `basket` is the cart's own description of its cells, nested
	## here as it is, and `sending` holds each order asked for until an
	## effect site sends it.
	store = Engine.store(
		Shop.CornerShop,
		{
			basket: Cart.cells({}),
			notice: Engine.cell("Welcome."),
			orders: Engine.cell(0.U64),
			sending: Engine.cell(Engine.outbox({})),
		}.Engine.Cells,
	)

	## The handles on the store's cells.
	h = Shop.store.handles()

	program : Engine.Program
	program = Engine.program_store({ storage_keys: [], max_inflight: 32 }, |_boot| Shop.store, |_boot| Shop.view({}))
	# endregion store

	## What the shop sells.
	shelf : List(Cart.Product)
	shelf = [{ name: "Tea", price: 4 }, { name: "Bread", price: 3 }, { name: "Jam", price: 5 }]

	# region decisions
	## What adding `product` writes: the cart with one more of it, and a
	## notice saying so.
	added : Cart.Product -> List(Engine.Write(_))
	added = |product| [
		Shop.h.basket.cells.cart.change(|cart| cart.add(product)),
		Shop.h.notice.put("Added ${product.name}."),
	]

	## What "Check out" writes, given the cart as it is when the button is
	## pressed: nothing for an empty cart; otherwise its total is posted for
	## sending and the notice says so.
	checked_out : Cart -> List(Engine.Write(_))
	checked_out = |cart|
		if cart.size() == 0 {
			[]
		} else {
			[
				Shop.h.sending.change(|orders| orders.post(cart.total())),
				Shop.h.notice.put("Sending your order."),
			]
		}
	# endregion decisions

	# region answer
	## What the server's answer to an order of `total` writes. An accepted
	## order is counted and starts the basket again; a refused one leaves
	## the basket as it was.
	ordered : U64, Engine.Res -> List(Engine.Write(_))
	ordered = |total, res|
		match Engine.http_text(res) {
			Ok(_) => [
				Shop.h.orders.change(|count| count + 1),
				Shop.h.basket.reset,
				Shop.h.notice.put("Order placed for ${total.to_str()}."),
			]
			Err(_) => [Shop.h.notice.put("The order was not placed. Your cart is as it was.")]
		}

	## The site that sends each order posted, and decides what its answer
	## writes.
	ordering : {} -> Elem(ctx)
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	ordering = |{}|
		Engine.on_post(
			Shop.h.sending.val(),
			|total| [Http({ method: "POST", url: "/api/orders", headers: [], body: total.to_str(), timeout_ms: 5000 })],
			Engine.react(Shop.ordered),
		)
	# endregion answer

	# region depth
	## One product, in a row of the list. The row reads the cart and adds to
	## it with no `lift`: a cell needs nothing to reach a deeper scope.
	product_row : RowRef(ctx, Cart.Product) -> Elem(Row(ctx, Cart.Product))
		where [ctx.store : () -> Engine.Reach(ctx, _)]
	product_row = |row| {
		name = row.key()
		held = name.map2(Shop.h.basket.cells.cart.val(), |product, cart| "${cart.quantity(product).to_str()} in cart")
		Html.li(
			[],
			[
				Engine.text_v(row.field(|item| "${item.name}, ${item.price.to_str()} ")),
				Html.span_v(held, [Html.aria_label_v(name.map(|product| "${product} in cart"))]),
				Html.button_v(name.map(|product| "Add ${product}"), [], Engine.handle_by(row.item(), |item, _| Shop.added(item))),
			],
		)
	}
	# endregion depth

	# region view
	## The page. It hands the cart its cells: this module knows the store
	## and the cart, and the cart knows neither the store nor this module.
	view : {} -> Elem(Engine.StoreRoot(_))
	view = |{}| {
		basket = Shop.h.basket.cells
		# region check-out
		check_out = Html.button("Check out", [], Engine.handle_by(basket.cart.val(), |cart, _| Shop.checked_out(cart)))
		# endregion check-out
		Html.div(
			"shop",
			[
				Html.p_v(Shop.h.notice.val(), [Engine.test_id("notice")]),
				Html.p_v(Shop.h.orders.val().map(|count| "Orders placed: ${count.to_str()}"), [Engine.test_id("orders")]),
				Html.ul([], [Engine.each(Engine.const(Shop.shelf), |item| item.name, |row| Shop.product_row(row))]),
				Cart.view(basket),
				check_out,
				Shop.ordering({}),
			],
		)
	}
	# endregion view
}

# region expects
## Adding a product writes the cart and the notice together.
expect {
	after = Shop.store.after(Shop.added({ name: "Tea", price: 4 }))
	basket = Shop.h.basket.cells

	actual =
		\\tea: ${after.read(basket.cart).quantity("Tea").to_str()}
		\\notice: ${after.read(Shop.h.notice)}
	expected =
		\\tea: 1
		\\notice: Added Tea.
	actual == expected
}

## Checking out an empty cart writes nothing.
expect Shop.checked_out(Cart.empty).len() == 0
# endregion expects

# region reset-expect
## An accepted order is counted and starts the basket again, the note with
## the cart; a refused one keeps both.
expect {
	basket = Shop.h.basket.cells
	filled = Shop.store.after(Shop.added({ name: "Tea", price: 4 })).after([basket.note.put("Leave it by the door")])
	placed = filled.after(Shop.ordered(4, Http({ status: 201, headers: [], body: "" })))
	refused = filled.after(Shop.ordered(4, Timeout))

	actual =
		\\placed: ${placed.read(Shop.h.orders).to_str()} orders, ${placed.read(basket.cart).size().to_str()} in the cart, note "${placed.read(basket.note)}"
		\\refused: ${refused.read(Shop.h.orders).to_str()} orders, ${refused.read(basket.cart).size().to_str()} in the cart, note "${refused.read(basket.note)}"
	expected =
		\\placed: 1 orders, 0 in the cart, note ""
		\\refused: 0 orders, 1 in the cart, note "Leave it by the door"
	actual == expected
}
# endregion reset-expect
