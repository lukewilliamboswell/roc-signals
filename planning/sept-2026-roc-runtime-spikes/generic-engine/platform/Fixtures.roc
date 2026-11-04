import Engine

Fixtures := {}.{
	Task : { title : Str, done : Bool, labels : List(Str), revision : U64 }
	TaskView : { caption : Str, enabled : Bool }
	Cart : { price : U64, quantity : U64, note : Str }
	Shipping : [Free, Paid(U64)]
	CartView : { total : U64, shipping : Shipping }
	Model : { tasks : Engine.Graph(Task, Str, Bool, TaskView), carts : Engine.Graph(Cart, U64, Shipping, CartView) }

	main : { init : U64 -> Model, update : Model, U64, U64, U64 -> Model, check : Model, U64, U64, U64, U64, U64, U64 -> Model }
	main = { init, update, check }

	task : U64 -> Task
	task = |value| { title: "a heap-backed task title whose contents remain stable", done: value.rem_by(2) == 1, labels: ["one heap-backed label retained inside a nested list", "another heap-backed label retained inside a nested list"], revision: value }

	cart : U64 -> Cart
	cart = |value| { price: 7, quantity: value, note: "a heap-backed shopping cart note with independent ownership" }

	## Different rows retain different captured text and validation/shipping limits.
	init : U64 -> Model
	init = |rows| {
		var $tasks = List.with_capacity(rows)
		var $carts = List.with_capacity(rows)
		var $row = 0.U64
		while $row < rows {
			prefix = "task component ${$row.to_str()} has a deliberately long captured prefix: "
			minimum = $row.rem_by(3)
			limit = 20 + $row.rem_by(7)
			$tasks = $tasks.append({ source: task(0), ops: {
				left: |t| "${prefix}${t.title}",
				right: |t| !t.done and t.labels.len() >= minimum,
				join: |caption, enabled| { caption, enabled },
			} })
			$carts = $carts.append({ source: cart(0), ops: {
				left: |c| c.price * c.quantity,
				right: |c| if c.quantity >= limit { Free } else { Paid(5) },
				join: |subtotal, shipping| { total: subtotal + (match shipping { Free => 0, Paid(fee) => fee }), shipping },
			} })
			$row = $row + 1
		}
		{ tasks: Engine.create($tasks), carts: Engine.create($carts) }
	}

	# Primitive op selects the fixture only; dependency work is all in Engine.
	update : Model, U64, U64, U64 -> Model
	update = |{ tasks, carts }, op, row, value| {
		if op == 0 { { tasks: Engine.update(tasks, row, task(value)), carts } }
		else if op == 1 { { tasks, carts: Engine.update(carts, row, cart(value)) } }
		else { crash "unknown fixture operation" }
	}

	## Independent fixture assertions validate all four cached types after handoff.
	check : Model, U64, U64, U64, U64, U64, U64 -> Model
	check = |model, kind, row, value, calls, prunes, emitted| {
		w = if kind == 0 {
			got = Engine.get(model.tasks, row)
			if got.source != task(value) { crash "task source mismatch" }
			caption = "task component ${row.to_str()} has a deliberately long captured prefix: a heap-backed task title whose contents remain stable"
			if got.left != caption { crash "captured task prefix mismatch" }
			if got.right != (value.rem_by(2) == 0) { crash "task validation mismatch" }
			if got.output != { caption, enabled: value.rem_by(2) == 0 } { crash "task output mismatch" }
			Engine.work(model.tasks)
		} else {
			got = Engine.get(model.carts, row)
			shipping = if value >= 20 + row.rem_by(7) { Free } else { Paid(5) }
			if got.source != cart(value) { crash "cart source mismatch" }
			if got.left != value * 7 { crash "subtotal mismatch" }
			if got.right != shipping { crash "captured shipping limit mismatch" }
			if got.output != { total: value * 7 + (match shipping { Free => 0, Paid(fee) => fee }), shipping } { crash "cart output mismatch" }
			Engine.work(model.carts)
		}
		if w != { calls, prunes, emitted } { crash "work mismatch" }
		model
	}
}
